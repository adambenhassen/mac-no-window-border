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

/// A suspended receive can still copy out a message and replace x0 (its buffer pointer) with a
/// 32-bit kr. Only inspect this after the park check on a suspended arm64 CF run-loop thread.
enum ReceiveHandback {
    /// Give a suspended receive at most 1 ms and eight state reads, independently of the entry
    /// hunt's much longer budget. The clock is checked after IPC too: a late result is left for
    /// the target to consume on resume. Scheduling and IPC can overrun a deadline, so this is a
    /// limit on further work, not a real-time guarantee of how long suspension lasts.
    static func settle(from stopped: arm_thread_state64_t, instructionBeforePC: UInt32,
                       entryDeadline: UInt64, now: () -> UInt64, interrupt: () -> Bool,
                       readState: () -> arm_thread_state64_t?, pause: () -> Void) -> arm_thread_state64_t? {
        let started = now()
        guard started < entryDeadline, instructionBeforePC == 0xD400_1001 else { return nil }
        let deadline = min(entryDeadline, started + 1_000_000)
        if let finished = state(from: stopped, instructionBeforePC: instructionBeforePC) { return finished }
        guard interrupt() else { return nil }
        for attempt in 0..<8 {
            guard now() < deadline else { return nil }
            guard let current = readState(), current.__pc == stopped.__pc else { return nil }
            guard now() < deadline else { return nil }
            if let finished = state(from: current, instructionBeforePC: instructionBeforePC) { return finished }
            if attempt < 7 { pause() }
        }
        return nil
    }

    static func state(from state: arm_thread_state64_t, instructionBeforePC: UInt32) -> arm_thread_state64_t? {
        // Require the return PC after svc #0x80. XNU's arm64 executable loader requires a
        // 4 GiB pagezero, so a valid buffer pointer cannot be a zero-extended 32-bit Mach kr.
        guard instructionBeforePC == 0xD400_1001, state.__x.0 <= UInt64(UInt32.max) else { return nil }
        var result = state
        // INTERRUPTED received no message. A timeout lets CF service our queued block; all
        // other results, including SUCCESS/TOO_LARGE and errors, belong to the target.
        if result.__x.0 == 0x1000_4005 { result.__x.0 = 0x1000_4003 }
        return result
    }
}

extension MainThread {
    /// Stop user execution before inspecting a frame. An in-flight kernel receive can continue;
    /// its result must settle before the executor changes user state.
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
    /// Capture the settled receive state and return through its original syscall wrapper.
    public init(from state: arm_thread_state64_t) {
        var registers: [UInt64] = []
        withUnsafeBytes(of: state) { raw in
            // x0…x28, then x29 (fp) and x30 (lr): 31 words, flat, at the start of the struct.
            for index in 0..<31 { registers.append(raw.load(fromByteOffset: index * 8, as: UInt64.self)) }
        }
        self.init(registers: registers, sp: state.__sp, pc: state.__pc)
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

    /// The park check identifies a safe run-loop frame, not a completed kernel receive. The
    /// executor must still settle its return value before modifying the suspended thread.
    public func parkState(from state: arm_thread_state64_t) -> ParkState {
        guard let innerFrame = symbolName(at: state.__pc), Self.idleTraps.contains(innerFrame) else {
            return .running
        }
        // Keep entry restricted to the untimed run-loop wait. Timed receives are CF servicing
        // traffic; deferring them preserves the existing park gate. The executor now returns
        // through the syscall wrapper with the settled result instead of restarting a raw trap.
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
