import Darwin
import Foundation

/// Whether a thread is waiting inside its run loop. Only then does it hold no application lock,
/// which is what makes running our calls in it safe.
public enum ParkState: Equatable {
    case parked
    case running
    case unknown
}

public struct MainThread {
    public let port: thread_act_t
    /// The system-wide thread id from the kernel, comparable across processes.
    public let id: UInt64

    /// `TH_WAIT` from <mach/machine/thread_status.h>: the thread is asleep in the kernel, which is
    /// what a run loop waiting in `mach_msg2_trap` reports. The SDK does not export the kernel's
    /// run-state constants to Swift; tests/probe.sh prints the number for a parked app and gets 3.
    public static let asleepRunState: Int32 = 3
}

extension MainThread {
    /// Stop and restart the thread. The executor stops it *before* reading its state: a thread that
    /// wakes between a read and an entry is running app code, and the read is a frame the app has
    /// left (measured: entering on it dies). While the thread is stopped, what we read is exactly
    /// what it resumes with, so a check taken now cannot go stale.
    @discardableResult
    public func suspend() -> kern_return_t { thread_suspend(port) }

    @discardableResult
    public func resume() -> kern_return_t { thread_resume(port) }

    /// What the kernel says the thread is doing. A thread parked in its run loop's mach call reports
    /// TH_WAIT; one that has woken and is running app code reports TH_RUN. This is the only way to
    /// know that the state read a moment ago is still the state the thread has.
    public func runState() -> Int32? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.run_state : nil
    }

    public func state() -> arm_thread_state64_t? {
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? state : nil
    }

    public func setState(_ state: arm_thread_state64_t) -> Bool {
        var mutable = state
        let count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<integer_t>.size)
        return withUnsafeMutablePointer(to: &mutable) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_set_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, count)
            }
        } == KERN_SUCCESS
    }
}

/// The app's own thread state, for the generated code to put back before it jumps away.
extension ThreadHandback {
    /// `restartAt` is the *start* of the call the thread was sitting in: a parked thread's pc is
    /// the instruction after the trap, and returning there would hand CoreFoundation the result of
    /// a call it never made.
    public init(from state: arm_thread_state64_t, restartAt: UInt64) {
        var registers: [UInt64] = []
        withUnsafeBytes(of: state) { raw in
            // x0…x28, then x29 (fp) and x30 (lr): 31 words, flat, at the start of the struct.
            for index in 0..<31 { registers.append(raw.load(fromByteOffset: index * 8, as: UInt64.self)) }
        }
        self.init(registers: registers, sp: state.__sp, pc: restartAt)
    }
}

/// The kernel's system-wide id for a thread, the only number that means the same thing in two
/// processes: a thread port is a name in one task, so an exception message's thread port has to be
/// matched by its id, not by the port. nil when the port is not a thread.
func kernelThreadID(of thread: mach_port_t) -> UInt64? {
    var info = thread_identifier_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.thread_id : nil
}

extension TargetTask {
    private static let idleTraps: Set<String> = ["mach_msg2_trap", "mach_msg_trap"]
    private static let runLoopPortFrame = "__CFRunLoopServiceMachPort"
    private static let maxFrames = 10
    /// `MACH_RCV_MSG` / `MACH_RCV_TIMEOUT` from <mach/message.h> (this SDK: 0x2 / 0x100; 0x10 is
    /// `MACH_SEND_TIMEOUT`), request bits of the in-flight `mach_msg2` (the request sits in x1;
    /// x0 is the message pointer).
    private static let machRcvMsg: UInt64 = 0x2
    private static let machRcvTimeout: UInt64 = 0x100

    /// The process's main thread. A process's first thread is created at exec, before any
    /// `pthread_create`, and the kernel numbers thread ids in creation order, so the main thread
    /// is the one with the smallest id. Returns nil rather than guessing: nothing here may run
    /// on another thread.
    public func mainThread() -> MainThread? {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(port, &threads, &count) == KERN_SUCCESS, let list = threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(UInt(count) * UInt(MemoryLayout<thread_act_t>.size)))
        }
        // `task_threads` hands us a send right per thread. Every one that is not the answer is
        // dropped here; the chosen port's life belongs to the MainThread we return.
        var found: MainThread?
        for index in 0..<Int(count) {
            guard let id = kernelThreadID(of: list[index]) else {
                mach_port_deallocate(mach_task_self_, list[index])
                continue
            }
            if found == nil || id < found!.id {
                if let previous = found { mach_port_deallocate(mach_task_self_, previous.port) }
                found = MainThread(port: list[index], id: id)
            } else {
                mach_port_deallocate(mach_task_self_, list[index])
            }
        }
        return found
    }

    public func parkState(of main: MainThread) -> ParkState {
        guard let state = main.state() else { return .unknown }
        return parkState(from: state)
    }

    /// The decision for a thread state we have already read. The executor reads it with the thread
    /// stopped, so the answer cannot change underneath the decision.
    public func parkState(from state: arm_thread_state64_t) -> ParkState {
        guard let innerFrame = symbolName(at: state.__pc), Self.idleTraps.contains(innerFrame) else {
            return .running
        }
        // The trap is a `mach_msg2` call in flight, its request in x1. The entry restarts that
        // call from its start, and the raw `mach_msg2_trap` rejects a **timed** receive — one
        // whose request carries `MACH_RCV_TIMEOUT` (0x100) — with `MACH_RCV_INVALID_ARGUMENTS`
        // (0x10004013): reproduced in-process and in the stub's own absorber (identical kr,
        // 2026-10-20). CoreFoundation's `__CFRunLoopServiceMachPort` tolerates only {success,
        // TOO_LARGE (0x10004004), TIMED_OUT (0x10004003)} — `INVALID_ARGUMENTS` reaches its
        // "unexpected kr" trap and the app dies (`__CFRunLoopServiceMachPort.cold.1`; the
        // iTerm/Vivaldi class; five watch-captured hostapps, every death this kr). CF switches
        // the service-port wait to its timed shape while timers are pending, i.e. exactly when
        // wake traffic is being serviced; plain parks (0x507000806-form, no 0x100) restart
        // cleanly — the form every clean entry ran on. Refuse the timed shape. (Earlier gates
        // guarded 0x400 = `MACH_RCV_INTERRUPT`, then 0x10 = `MACH_SEND_TIMEOUT` — both the wrong
        // bit; the header values are the ground truth.) Deferring the servicing moment is the
        // same answer as any busy target; it lasts microseconds, and the scan loop retries
        // every 250 ms.
        guard state.__x.1 & Self.machRcvMsg != 0, state.__x.1 & Self.machRcvTimeout == 0 else {
            return .running
        }
        var frames = [innerFrame]
        var link = state.__fp == 0 ? state.__sp : state.__fp
        for _ in 0..<Self.maxFrames {
            guard let nextLink = readWord(at: link), let returnAddress = readWord(at: link &+ 8),
                  nextLink > link else { break }
            frames.append(symbolName(at: returnAddress) ?? "?")
            if frames.contains(Self.runLoopPortFrame) { return .parked }
            link = nextLink
        }
        return frames.contains(Self.runLoopPortFrame) ? .parked : .running
    }

    /// Reads 8 bytes of the target's memory.
    func readWord(at address: UInt64) -> UInt64? {
        var value: UInt64 = 0
        var sent: vm_size_t = 0
        let kr = withUnsafeMutableBytes(of: &value) { raw in
            vm_read_overwrite(port, vm_address_t(address), vm_size_t(MemoryLayout<UInt64>.size),
                              vm_address_t(bitPattern: raw.baseAddress!), &sent)
        }
        return kr == KERN_SUCCESS ? value : nil
    }

    /// The shared cache is mapped at one address for the whole boot, so the target's code
    /// addresses can be symbolicated from this process.
    private func symbolName(at address: UInt64) -> String? {
        guard address != 0, let pointer = UnsafeRawPointer(bitPattern: Int(truncatingIfNeeded: address)) else { return nil }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let name = info.dli_sname else { return nil }
        return String(cString: name)
    }
}
