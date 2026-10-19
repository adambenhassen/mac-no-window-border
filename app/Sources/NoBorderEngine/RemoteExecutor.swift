import Darwin
import Foundation

public enum RunResult: Equatable {
    case ok
    case notParked
    case timedOut
    case failed(String)
}

/// Runs a `RemoteScript` inside another process: read the parked main thread, write the script and
/// its data into the target, point the thread at it and end its run-loop wait so it gets there.
/// The script hands the thread back to the app itself; we only read a flag to see that it did.
public final class RemoteExecutor {
    private let task: TargetTask

    /// r-x: the call script, and the data it reads. One region is enough for both because an
    /// executable region can still be read.
    private var codeBase: UInt64 = 0
    private var codeBytes = 0

    /// r-w: the stack the AppKit calls run on. Apple Silicon will not give one region write and
    /// execute at the same time (`vm_protect` RWX → KERN_PROTECTION_FAILURE), so the stack has to
    /// be a region of its own — and keeping it ours means the target's own stack is never touched.
    private var stackBase: UInt64 = 0
    private static let stackBytes = 16 * 1024

    /// What the completion flag holds before a run: the script writes zero there, so zero after a
    /// run means it was this run that wrote it.
    private static let flagNotDone: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

    public init(task: TargetTask) { self.task = task }

    deinit { releaseScratch() }

    /// The result, and how long in nanoseconds the target's main thread was running our code
    /// instead of its own — measured from ending its run-loop wait to reading the completion flag.
    public func run(_ script: RemoteScript, on main: MainThread, addresses: AddressTable,
                   stopLimit: TimeInterval = 0.2) -> (result: RunResult, stopNanoseconds: Int) {
        guard let parked = main.state() else { return (.failed("could not read the thread state"), 0) }
        guard task.parkState(from: parked) == .parked else { return (.notParked, 0) }

        let started = DispatchTime.now().uptimeNanoseconds
        let handback = ThreadHandback(from: parked, restartAt: entryOf(parked.__pc))
        let code = Trampoline.code(script, addresses: addresses, handback: handback)
        let data = Trampoline.data(script, addresses: addresses, handback: handback)
        let dataAt = Trampoline.dataOffset(codeWordCount: code.count)
        guard ensureCode(bytes: dataAt + data.count), ensureStack(),
              writeScript(code, data, dataBytes: data.count, at: dataAt), markFlagUnfinished()
        else {
            return (.failed("could not write the call script"), elapsedSince(started))
        }

        var enter = parked
        enter.__pc = codeBase
        enter.__sp = stackTop                                  // 16-aligned, as the ABI requires
        enter.__fp = 0
        enter.__lr = 0
        guard main.setState(enter) else {
            return (.failed("could not enter the call script"), elapsedSince(started))
        }

        // A parked thread is inside a system call, in the kernel, and a new pc does nothing to it
        // there: it stays in TH_WAIT and the change is never applied. Ending the call makes the
        // kernel return it to user space, which is where it picks the new pc up. If the call cannot
        // be ended we put the thread's state back and leave it alone.
        let underOurControl = DispatchTime.now().uptimeNanoseconds
        guard thread_abort(main.port) == KERN_SUCCESS else {
            _ = main.setState(parked)
            return (.failed("could not end the run loop's wait"), elapsedSince(started))
        }
        let result = waitForCompletion(at: flagAddress, deadline: underOurControl + UInt64(stopLimit * 1_000_000_000))
        let stop = result == .ok ? Int(DispatchTime.now().uptimeNanoseconds - underOurControl)
                                : elapsedSince(started)
        return (result, stop)
    }

    public func releaseScratch() {
        if codeBase != 0 {
            vm_deallocate(task.port, vm_address_t(codeBase), vm_size_t(codeBytes))
            codeBase = 0
            codeBytes = 0
        }
        if stackBase != 0 {
            vm_deallocate(task.port, vm_address_t(stackBase), vm_size_t(Self.stackBytes))
            stackBase = 0
        }
    }

    private var stackTop: UInt64 { stackBase + UInt64(Self.stackBytes) - 16 }

    /// The word the script zeroes when its last call has returned. It is above the stack the calls
    /// use, so nothing else writes there.
    private var flagAddress: UInt64 { stackTop + UInt64(Trampoline.completionFlagOffset) }

    private func waitForCompletion(at flag: UInt64, deadline: UInt64) -> RunResult {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let value = task.readWord(at: flag) else {
                return .failed("could not read the completion flag")   // Task 5: .faulted
            }
            if value == 0 { return .ok }
        }
        return .timedOut
    }

    private func markFlagUnfinished() -> Bool {
        var sentinel = Self.flagNotDone
        return withUnsafeBytes(of: &sentinel) { buffer in
            write(bytes: buffer.baseAddress!, count: buffer.count, at: flagAddress)
        }
    }

    /// The address of the function an address inside it belongs to — for a parked thread that is
    /// `mach_msg2_trap`, whose first instruction is the trap itself. Going back there re-issues the
    /// run loop's call; going back to the address we read would return from a call that had ended.
    private func entryOf(_ address: UInt64) -> UInt64 {
        guard let pointer = UnsafeRawPointer(bitPattern: Int(truncatingIfNeeded: address)) else { return address }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0 else { return address }
        return UInt64(bitPattern: Int64(Int(bitPattern: info.dli_saddr)))
    }

    private func elapsedSince(_ started: UInt64) -> Int {
        Int(DispatchTime.now().uptimeNanoseconds - started)
    }

    private func ensureCode(bytes: Int) -> Bool {
        if codeBytes >= bytes { return true }
        if codeBase != 0 {
            vm_deallocate(task.port, vm_address_t(codeBase), vm_size_t(codeBytes))
            codeBase = 0
            codeBytes = 0
        }
        var address: vm_address_t = 0
        guard vm_allocate(task.port, &address, vm_size_t(bytes), 1) == KERN_SUCCESS else { return false }
        codeBase = UInt64(address)
        codeBytes = bytes
        return true
    }

    private func ensureStack() -> Bool {
        if stackBase != 0 { return true }
        var address: vm_address_t = 0
        guard vm_allocate(task.port, &address, vm_size_t(Self.stackBytes), 1) == KERN_SUCCESS else { return false }
        stackBase = UInt64(address)
        return true
    }

    /// Write the script while its region is still writable, then make it executable.
    private func writeScript(_ code: [UInt32], _ data: [UInt8], dataBytes: Int, at dataAt: Int) -> Bool {
        let writable: vm_prot_t = VM_PROT_READ | VM_PROT_WRITE
        let executable: vm_prot_t = VM_PROT_READ | VM_PROT_EXECUTE
        guard vm_protect(task.port, vm_address_t(codeBase), vm_size_t(codeBytes), 0, writable) == KERN_SUCCESS
        else { return false }
        guard code.withUnsafeBytes({ buffer in
            write(bytes: buffer.baseAddress!, count: buffer.count, at: codeBase)
        }) else { return false }
        guard data.withUnsafeBytes({ buffer in
            write(bytes: buffer.baseAddress!, count: buffer.count, at: codeBase + UInt64(dataAt))
        }) else { return false }
        return vm_protect(task.port, vm_address_t(codeBase), vm_size_t(codeBytes), 0, executable) == KERN_SUCCESS
    }

    private func write(bytes: UnsafeRawPointer, count: Int, at address: UInt64) -> Bool {
        vm_write(task.port, vm_address_t(address), vm_offset_t(bitPattern: bytes),
                 mach_msg_type_number_t(count)) == KERN_SUCCESS
    }
}
