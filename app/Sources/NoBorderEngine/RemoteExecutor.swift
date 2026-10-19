import Darwin
import Foundation

public enum RunResult: Equatable {
    case ok
    case notParked
    case timedOut
    /// The call script faulted in the target; the fault guard handed the thread back to the app.
    case faulted
    case failed(String)
}

/// Runs a `RemoteScript` inside another process: read the parked main thread, write the script and
/// its data into the target, point the thread at it and end its run-loop wait so it gets there.
/// The script hands the thread back to the app itself; we only read a flag to see that it did. If
/// the script faults, `FaultGuard` answers for the thread instead, and the app never sees the fault.
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
    /// run means it was this run that wrote it. The same sentinel marks the result word unread.
    private static let flagNotDone: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

    /// The word the last script that finished wrote at `Trampoline.resultOffset`, or nil if it wrote
    /// none. Read after a run, never while one is in progress; a run that did not finish leaves the
    /// sentinel there, which reads as nil.
    public private(set) var lastResultWord: UInt64?

    public init(task: TargetTask) { self.task = task }

    deinit { releaseScratch() }

    /// The result, and how long in nanoseconds the target's main thread was out of its own code —
    /// measured from ending its run-loop wait to the point the thread went back to the app, whether
    /// that was the script's last call, the fault guard's reply, or us giving up.
    ///
    /// `stopLimit` bounds the wait for the script once it is running; `enterLimit` bounds the search
    /// for a moment when the thread is asleep in its run loop and stays that way. A target that never
    /// settles comes back `.notParked`, which is the same answer the park check gives and means the
    /// same thing: try again later. Only the time between entering and finishing is the app's stall,
    /// which is what the phase is measured on; looking for a parked moment is free for the app —
    /// reading `run_state` costs it nothing it was not already doing.
    ///
    /// The generous `enterLimit` is not padding: AppKit's own work after these calls (re-compositing
    /// a full-screen window's shadow and titlebar) keeps its main thread busy for hundreds of
    /// milliseconds, sometimes seconds, and a target that busy is simply not servable yet.
    public func run(_ script: RemoteScript, on main: MainThread, addresses: AddressTable,
                   stopLimit: TimeInterval = 0.2, enterLimit: TimeInterval = 2.5)
                   -> (result: RunResult, stopNanoseconds: Int) {
        guard let parked = main.state() else { return (.failed("could not read the thread state"), 0) }
        guard task.parkState(from: parked) == .parked else { return (.notParked, 0) }

        let started = DispatchTime.now().uptimeNanoseconds
        let handback = ThreadHandback(from: parked, restartAt: entryOf(parked.__pc))
        // The state the fault guard puts on the thread if the script faults: the app's own registers
        // and the start of the run-loop call it was sitting in, exactly where the script would have
        // handed it back.
        var backToTheApp = parked
        backToTheApp.__pc = handback.pc
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

        // A parked thread is inside a system call, in the kernel, and a new pc does nothing to it
        // there: it stays in TH_WAIT and the change is never applied. Ending the call makes the
        // kernel return it to user space, which is where it picks the new pc up. If the call cannot
        // be ended we put the thread's state back and leave it alone.
        let faults = FaultGuard(task: task)
        guard faults.install() else {
            return (.failed("could not install the fault guard"), elapsedSince(started))
        }
        // The state above is the app's own only while the thread is still asleep inside its
        // run-loop call. Anything that wakes it — a timer, an event — and the app has been running
        // its own code with its own registers; entering then runs the script in the middle of that,
        // and the state handed back afterwards belongs to a frame the app has left. Measured: the
        // app jumps to a signed return address and dies in EXC_BAD_ACCESS. So the entry is retried
        // until the thread is found asleep again, and a target that will not settle is left alone.
        var underOurControl: UInt64 = 0
        var entered = false
        while DispatchTime.now().uptimeNanoseconds < started + UInt64(enterLimit * 1_000_000_000) {
            // The one window that matters: between reading the state and ending the call, the app must
            // not have run any of its own code. Checking costs a thread_info call; if the app is
            // awake, the state we saved is not its state, so ask again shortly.
            guard main.runState() == MainThread.asleepRunState else { usleep(200); continue }
            guard main.setState(enter) else {
                faults.remove()
                return (.failed("could not enter the call script"), elapsedSince(started))
            }
            underOurControl = DispatchTime.now().uptimeNanoseconds
            guard thread_abort(main.port) == KERN_SUCCESS else {
                _ = main.setState(parked)   // the thread is asleep; this is its state back
                continue
            }
            entered = true
            break
        }
        guard entered else {
            faults.remove()
            // The app was never taken out of its own code, so it was not stopped: the phase measures
            // that number, and 0 is the honest answer for a target we only looked at.
            return (.notParked, 0)
        }
        let result = waitForCompletion(at: flagAddress, deadline: underOurControl + UInt64(stopLimit * 1_000_000_000),
                                      faults: faults, on: main, restoringTo: backToTheApp)
        faults.remove()
        lastResultWord = result == .ok ? readResultWord() : nil
        // Once the thread is back with the app — the script's own jump, or our reply to a fault —
        // the stop is over. Anything else (a timeout, a target that went away) is counted from the
        // start, because we do not know when, or whether, it came back.
        let stop = (result == .ok || result == .faulted) ? Int(DispatchTime.now().uptimeNanoseconds - underOurControl)
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

    /// The stack pointer the script starts on: 16-aligned, as the ABI requires, and 32 bytes below
    /// the top of the region so the two words it writes (the completion flag at +8 and the result at
    /// +16) are inside it. The calls grow down from here, so nothing they touch is a word we read.
    private var stackTop: UInt64 { stackBase + UInt64(Self.stackBytes) - 32 }

    /// The word the script zeroes when its last call has returned. It is above the stack the calls
    /// use, so nothing else writes there.
    private var flagAddress: UInt64 { stackTop + UInt64(Trampoline.completionFlagOffset) }

    private func waitForCompletion(at flag: UInt64, deadline: UInt64, faults: FaultGuard,
                                  on main: MainThread, restoringTo state: arm_thread_state64_t) -> RunResult {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let value = task.readWord(at: flag) else {
                return .failed("could not read the completion flag")
            }
            if value == 0 { return .ok }
            // The flag is never written by a script that faults, so a fault is the other way this
            // wait ends. The flag is read first: if the script finished, a fault that arrived after
            // it belongs to the app, not to us.
            if faults.tookFault(on: main, restoringTo: state) { return .faulted }
        }
        return .timedOut
    }

    /// The word the script hands back to us, beside the completion flag and above the stack its
    /// calls use, so nothing else writes there.
    private var resultAddress: UInt64 { stackTop + UInt64(Trampoline.resultOffset) }

    private func markFlagUnfinished() -> Bool {
        var sentinel = Self.flagNotDone
        return withUnsafeBytes(of: &sentinel) { buffer in
            // Both words at once: a result word left over from a previous run would be read as if
            // this script had written it.
            write(bytes: buffer.baseAddress!, count: buffer.count, at: flagAddress)
                && write(bytes: buffer.baseAddress!, count: buffer.count, at: resultAddress)
        }
    }

    private func readResultWord() -> UInt64? {
        let value = task.readWord(at: resultAddress)
        return value == Self.flagNotDone ? nil : value
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
