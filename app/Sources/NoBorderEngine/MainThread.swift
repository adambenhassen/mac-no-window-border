import Darwin
import Foundation

/// Whether a thread is waiting inside its run loop. Only then does it hold no application lock,
/// which is what makes running our calls in it safe (same rule Phase 1 used over LLDB).
public enum ParkState: Equatable {
    case parked
    case running
    case unknown
}

public struct MainThread {
    public let port: thread_act_t
    /// The system-wide thread id from the kernel, comparable across processes.
    public let id: UInt64
}

extension MainThread {
    public func suspend() { thread_suspend(port) }
    public func resume() { thread_resume(port) }

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

extension TargetTask {
    private static let idleTraps: Set<String> = ["mach_msg2_trap", "mach_msg_trap"]
    private static let runLoopPortFrame = "__CFRunLoopServiceMachPort"
    private static let maxFrames = 10

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
        var found: MainThread?
        for index in 0..<Int(count) {
            guard let identity = identity(of: list[index]) else { continue }
            if found == nil || identity.id < found!.id {
                found = MainThread(port: list[index], id: identity.id)
            }
        }
        return found
    }

    private func identity(of thread: thread_act_t) -> (id: UInt64, handle: UInt64)? {
        var info = thread_identifier_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (info.thread_id, info.thread_handle)
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
