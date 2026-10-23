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

    /// A timed-out entry means a block of ours may still sit on the target's queue: its scratch
    /// regions retire to `pending` and are never rewritten, so the next entry runs on fresh
    /// pages and a target that was merely slow at one activation (measured 2026-10-20: the
    /// app's own activation burst queueing a block past the stop limit — three live apps
    /// quarantined at launch, rims left in place) is servable again. The target is given up on
    /// only when its queue is demonstrably jammed: the pending list is full, which is the
    /// hazard-1 discipline — we stop before our pages in it outnumber what it can ever drain.
    private var quarantined = false

    /// Retired, undrained regions tolerated before the target is given up on.
    private static let pendingLimit = 4

    private var absorbKrAddress: UInt64?
    private var absorbWordAddress: UInt64 = 0

    /// The absorber trap's port: a receive right allocated *in the target* (a cross-task
    /// insert into a name that does not exist there answers `KERN_INVALID_RIGHT`, kr 18,
    /// measured). The stub receives on the target's own port with a 1 ms timeout: the armed
    /// `thread_abort` interrupt is consumed by a valid-port receive (a null-port receive answers
    /// `MACH_RCV_INVALID_NAME` first and consumes nothing), and a receive fires no port guard (a
    /// null-port *send* raises `EXC_GUARD` on this OS — measured). The kernel picks the name.
    /// One port per target, created on the first dispatched run, deallocated at the end.
    private var absorbName: UInt64 = 0

    private func ensureAbsorbPort() {
        guard absorbName == 0 else { return }
        var name: mach_port_t = 0
        let kr = mach_port_allocate(task.port, MACH_PORT_RIGHT_RECEIVE, &name)
        guard kr == KERN_SUCCESS else {
            if ProcessInfo.processInfo.environment["NOBORDER_ABSORB_KR"] == "1" {
                NSLog("noborder: absorber port allocate in the target failed (kr=\(kr))")
            }
            return
        }
        absorbName = UInt64(name)
        if ProcessInfo.processInfo.environment["NOBORDER_ABSORB_KR"] == "1" {
            NSLog("noborder: absorber port allocated in the target: 0x" + String(name, radix: 16))
        }
    }

    /// `_kernelrpc_mach_port_destruct_trap(task, name, srdelta, guard)`: destroys a right in the
    /// target, send refs and all.
    /// `mach_port_deallocate` only drops a send ref — the receive right we allocated in the
    /// target survives it, leaking one right per executor (design review 2026-10-20: the target
    /// port namespace grew 0xb007→0xff07 across 80 probe processes). The plain
    /// `kernelrpc_mach_port_destruct` name is NOT exported on this OS (dlsym nil, measured
    /// 2026-10-20); the raw trap symbol is.
    private static let machPortDestruct: (@convention(c) (mach_port_t, mach_port_t, Int32, UInt64) -> kern_return_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "_kernelrpc_mach_port_destruct_trap") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (mach_port_t, mach_port_t, Int32, UInt64) -> kern_return_t).self)
    }()

    /// Regions released while their dispatched block may still sit on the app's main queue. The
    /// block's invoke, literal and flag live in those pages; freeing them makes the app jump into
    /// unmapped memory the moment the queue drains (measured 2026-10-20: a timedOut probe run, the
    /// CLI exited, the app died on the next drain). A later run frees a region once its flag has
    /// flipped — the flag says whether the block has run.
    /// `flagZeroSeen` is the first time we saw this region's flag flipped: the flag is written
    /// *inside* the block's own code, so a flip proves the block ran, not that it has returned
    /// from the region. Free only on a second sighting a quarter second later (review 2026-10-20).
    private typealias PendingRegion = (codeBase: UInt64, codeBytes: Int, stackBase: UInt64,
                                       stackBytes: Int, flag: UInt64, flagZeroSeen: UInt64)
    private var pending: [PendingRegion] = []

    /// The word the last script that finished wrote at `Trampoline.resultOffset`, or nil if it wrote
    /// none. Read after a run, never while one is in progress; a run that did not finish leaves the
    /// sentinel there, which reads as nil.
    public private(set) var lastResultWord: UInt64?

    /// The kr the dispatched stub's sacrificial absorber trap returned, read after a successful
    /// run; nil unless `NOBORDER_ABSORB_KR=1`. 0x10004005 = the `thread_abort` interrupt was armed
    /// and the absorber consumed it; 0x10004002 = the thread was not armed (`MACH_RCV_INVALID_NAME`
    /// from the null receive port). Tests only.
    public private(set) var lastAbsorbKr: UInt64?

    public init(task: TargetTask) { self.task = task }

    deinit {
        releaseScratch()
        if absorbName != 0 {
            if let destruct = Self.machPortDestruct {
                let kr = destruct(task.port, mach_port_t(absorbName), 1, 0)
                if kr != KERN_SUCCESS, ProcessInfo.processInfo.environment["NOBORDER_ABSORB_KR"] == "1" {
                    NSLog("noborder: absorber port destruct in the target failed (kr=\(kr))")
                }
            }
            mach_port_deallocate(task.port, mach_port_t(absorbName))
        }
    }

    /// The result, and how long in nanoseconds the target's main thread was out of its own code —
    /// measured from ending its run-loop wait to the point the thread went back to the app, whether
    /// that was the script's last call, the fault guard's reply, or us giving up.
    ///
    /// `stopLimit` bounds the wait for the script once it is running; `enterLimit` bounds the search
    /// for a moment when the thread is asleep in its run loop and stays that way. A target that never
    /// settles comes back `.notParked`, which is the same answer the park check gives and means the
    /// same thing: try again later. Only the time between entering and finishing is the app's stall,
    /// which is what the phase is measured on; an attempt costs the thread a stop-read-check-resume
    /// — microseconds, and never while it is in app code.
    ///
    /// The generous `enterLimit` is not padding: AppKit's own work after these calls (re-compositing
    /// a full-screen window's shadow and titlebar) keeps its main thread busy for hundreds of
    /// milliseconds, sometimes seconds, and a target that busy is simply not servable yet.
    public func run(_ script: RemoteScript, on main: MainThread, addresses: AddressTable,
                   stopLimit: TimeInterval = 0.2, enterLimit: TimeInterval = 0.25)
                   -> (result: RunResult, stopNanoseconds: Int) {
        guard !quarantined else { return (.notParked, 0) }
        reapPending()
        if pending.count >= Self.pendingLimit {
            quarantined = true
            NSLog("noborder: \(task.pid) parked after a stalled entry")
            return (.notParked, 0)
        }
        guard let first = main.state() else { return (.failed("could not read the thread state"), 0) }
        guard task.parkState(from: first) == .parked else { return (.notParked, 0) }
        guard ensureStack() else { return (.failed("could not write the call script"), 0) }

        let started = DispatchTime.now().uptimeNanoseconds
        let faults = FaultGuard(task: task)
        guard faults.install() else {
            return (.failed("could not install the fault guard"), elapsedSince(started))
        }

        // Suspend closes the race with user code, but not with the kernel receive. Settle that
        // receive before saving or replacing registers, or setState can overwrite the success
        // result of a message already copied into the app's buffer.
        var underOurControl: UInt64 = 0
        var backToTheApp = first
        var entered = false
        let useDispatch = !script.appKitProbe
        // A fault inside a dispatched block resumes at the block's epilogue, not at the parked
        // state: the thread is inside the app's libdispatch then, and the parked restore kills it.
        var blockResume: UInt64 = 0
        // The hunt sleeps a millisecond between attempts: each turn is stop-read-check-resume
        // (four IPCs), and a busy target that never parks was burning a visible slice of a core
        // at 200 µs (measured 2026-10-20, 1.8% during live window work). The servicing moment
        // lasts microseconds, and a 1 ms granularity costs at most one extra scan cycle — the
        // loop retries every 250 ms.
        while DispatchTime.now().uptimeNanoseconds < started + UInt64(enterLimit * 1_000_000_000) {
            guard main.suspend() == KERN_SUCCESS else { usleep(1000); continue }
            guard let stopped = main.state(), task.parkState(from: stopped) == .parked else {
                main.resume()
                usleep(1000)
                continue
            }
            // Abort before changing state, then wait for the kernel's final result. A timer or
            // message may win the race with the abort: that result must reach CoreFoundation.
            // On failure, simply resume; never restore the earlier, possibly stale snapshot.
            underOurControl = DispatchTime.now().uptimeNanoseconds
            guard let settled = settleReceive(on: main, stopped: stopped,
                                               deadline: started + UInt64(enterLimit * 1_000_000_000)) else {
                main.resume()
                let stop = elapsedSince(underOurControl)
                faults.remove()
                // Do not suspend this target repeatedly within the 250 ms hunt after a slow
                // receive. Its wrapper owns the unchanged result; the next scan can try again.
                return (.notParked, stop)
            }
            let handback = ThreadHandback(from: settled)
            backToTheApp = settled
            // The dispatched entry for every script that touches AppKit: the fabricated frame
            // queues a block and hands the thread straight back, and the selector sequence runs
            // as a block on the app's main queue. The block's invoke field names the block code
            // by absolute address, so the region is sized and allocated before the code is built.
            // The AppKit probe stays on the old path: one message, no window work, no port churn.
            if useDispatch { ensureAbsorbPort() }
            let sizing = Trampoline.DispatchContext(codeBase: 0, flagAddress: flagAddress,
                                                    resultAddress: resultAddress,
                                                    absorbPort: absorbName)
            let bytes = Trampoline.scratchBytes(script, addresses: addresses, handback: handback,
                                                dispatch: useDispatch ? sizing : nil)
            guard ensureCode(bytes: bytes) else {
                main.resume()
                faults.remove()
                return (.failed("could not write the call script"), elapsedSince(started))
            }
            var real = sizing
            real.codeBase = codeBase
            let code = Trampoline.code(script, addresses: addresses, handback: handback,
                                       dispatch: useDispatch ? real : nil)
            let data = Trampoline.data(script, addresses: addresses, handback: handback,
                                       dispatch: useDispatch ? real : nil)
            let dataAt = Trampoline.dataOffset(codeWordCount: code.count)
            absorbKrAddress = useDispatch ? stackTop &+ UInt64(Trampoline.absorbKrSpOffset) : nil
            absorbWordAddress = codeBase &+ UInt64(dataAt)
                &+ UInt64(Trampoline.absorbPortDataOffset(script: script))
            if useDispatch { blockResume = codeBase &+ UInt64(4 * (code.count - 8)) }
            guard writeScript(code, data, dataBytes: data.count, at: dataAt), markFlagUnfinished()
            else {
                main.resume()
                faults.remove()
                return (.failed("could not write the call script"), elapsedSince(started))
            }
            var enter = settled
            enter.__pc = codeBase
            enter.__sp = stackTop                              // 16-aligned, as the ABI requires
            enter.__fp = 0
            enter.__lr = 0
            guard main.setState(enter) else {
                main.resume()
                faults.remove()
                return (.failed("could not enter the call script"), elapsedSince(started))
            }
            // The receive has already finished. Aborting here would arm an interrupt for an
            // unrelated future call and cannot recover a result overwritten by setState.
            main.resume()
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
                                      faults: faults, on: main, restoringTo: backToTheApp,
                                      resumeAt: blockResume, frameLo: stackBase, frameHi: stackTop + 32)
        faults.remove()
        if result == .timedOut {
            // Retire the scratch, never rewrite it: the block can still sit on the app's queue,
            // and its pages go to `pending` to be reaped once its flag flips. The next entry
            // allocates fresh pages, so a target that was merely slow at one activation is
            // servable again; the target is given up on only when the pending list is full —
            // a queue demonstrably jammed.
            retireScratch()
            if pending.count >= Self.pendingLimit {
                quarantined = true
                NSLog("noborder: \(task.pid) parked after a stalled entry")
            }
        }
        lastResultWord = result == .ok ? readResultWord() : nil
        lastAbsorbKr = nil
        if result == .ok, ProcessInfo.processInfo.environment["NOBORDER_ABSORB_KR"] == "1",
           let absorbKrAddress {
            lastAbsorbKr = task.readWord(at: absorbKrAddress)
            if let word = task.readWord(at: absorbWordAddress) {
                NSLog("noborder: absorber kr=0x" + String(lastAbsorbKr ?? 0, radix: 16)
                      + " port word in data=0x" + String(word, radix: 16)
                      + " allocated=0x" + String(absorbName, radix: 16))
            }
        }
        // Once the thread is back with the app — the script's own jump, or our reply to a fault —
        // the stop is over. Anything else (a timeout, a target that went away) is counted from the
        // start, because we do not know when, or whether, it came back.
        let stop = (result == .ok || result == .faulted) ? Int(DispatchTime.now().uptimeNanoseconds - underOurControl)
                                                        : elapsedSince(started)
        return (result, stop)
    }

    /// Move the timed-out run's regions to the pending list: the flag there is the sentinel we
    /// wrote, so `reapPending` frees the pages once the block runs, and until then nobody
    /// rewrites them — the next entry allocates its own. (A timed-out run always has both
    /// regions: the stack is allocated before the code is written.)
    private func retireScratch() {
        if stackBase != 0 {
            pending.append((codeBase, codeBytes, stackBase, Self.stackBytes, flagAddress, 0))
        }
        codeBase = 0
        codeBytes = 0
        stackBase = 0
    }

    public func releaseScratch() {
        reapPending()
        if stackBase != 0 {
            // The flag answers "has the block run". Unreadable means the app is gone — nothing can
            // drain anything — so the pages can go.
            let flag = task.readWord(at: flagAddress)
            if flag == Self.flagNotDone {
                pending.append((codeBase, codeBytes, stackBase, Self.stackBytes, flagAddress, 0))
            } else {
                if codeBase != 0 {
                    vm_deallocate(task.port, vm_address_t(codeBase), vm_size_t(codeBytes))
                }
                vm_deallocate(task.port, vm_address_t(stackBase), vm_size_t(Self.stackBytes))
            }
        } else if codeBase != 0 {
            vm_deallocate(task.port, vm_address_t(codeBase), vm_size_t(codeBytes))
        }
        codeBase = 0
        codeBytes = 0
        stackBase = 0
    }

    /// Free pending regions whose block has run — twice: see `pending` on the flag's meaning.
    private func reapPending() {
        var kept: [PendingRegion] = []
        for var region in pending {
            guard task.readWord(at: region.flag) == 0 else {
                kept.append(region)
                continue
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard region.flagZeroSeen != 0, now - region.flagZeroSeen >= 250_000_000 else {
                if region.flagZeroSeen == 0 { region.flagZeroSeen = now }
                kept.append(region)
                continue
            }
            if region.codeBase != 0 {
                vm_deallocate(task.port, vm_address_t(region.codeBase), vm_size_t(region.codeBytes))
            }
            vm_deallocate(task.port, vm_address_t(region.stackBase), vm_size_t(region.stackBytes))
        }
        pending = kept
    }

    /// The stack pointer the script starts on: 16-aligned, as the ABI requires, and 32 bytes below
    /// the top of the region so the two words it writes (the completion flag at +8 and the result at
    /// +16) are inside it. The calls grow down from here, so nothing they touch is a word we read.
    private var stackTop: UInt64 { stackBase + UInt64(Self.stackBytes) - 32 }

    /// The word the script zeroes when its last call has returned. It is above the stack the calls
    /// use, so nothing else writes there.
    private var flagAddress: UInt64 { stackTop + UInt64(Trampoline.completionFlagOffset) }

    private func waitForCompletion(at flag: UInt64, deadline: UInt64, faults: FaultGuard,
                                  on main: MainThread, restoringTo state: arm_thread_state64_t,
                                  resumeAt: UInt64 = 0, frameLo: UInt64 = 1, frameHi: UInt64 = 0) -> RunResult {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let value = task.readWord(at: flag) else {
                return .failed("could not read the completion flag")
            }
            if value == 0 { return .ok }
            // The flag is never written by a script that faults, so a fault is the other way this
            // wait ends. The flag is read first: if the script finished, a fault that arrived after
            // it belongs to the app, not to us.
            if faults.tookFault(on: main, restoringTo: state, resumeAt: resumeAt,
                                frameLo: frameLo, frameHi: frameHi) { return .faulted }
            // The flag flips when the app's main queue drains the block, not inside our stop — a
            // busy target can take a whole servicing pass. Reading the flag and the fault port is
            // two IPC calls per turn, so the turn has to sleep: spinning this loop hot burned a
            // core on a live target (measured 2026-10-20, the app at 97% CPU in iTerm). Half a
            // millisecond keeps the measured stop (≈1.5 ms) inside noise.
            usleep(500)
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

    /// Finish the parked receive without letting the target run user code. `thread_abort_safely`
    /// can race a successful receive, and its return does not promise the saved x0 is final yet.
    /// Poll for the 32-bit result after svc; never overwrite an input pointer. A bounded failure
    /// leaves the suspended thread's state untouched for its own wrapper to use.
    private func settleReceive(on main: MainThread, stopped: arm_thread_state64_t,
                               deadline: UInt64) -> arm_thread_state64_t? {
        guard stopped.__pc >= 4,
              let instructions = task.readWord(at: stopped.__pc - 4),
              UInt32(truncatingIfNeeded: instructions) == Arc64.svcMachMsg2() else { return nil }
        let instruction = UInt32(truncatingIfNeeded: instructions)
        return ReceiveHandback.settle(from: stopped, instructionBeforePC: instruction,
                                      entryDeadline: deadline,
                                      now: { DispatchTime.now().uptimeNanoseconds },
                                      interrupt: { thread_abort_safely(main.port) == KERN_SUCCESS },
                                      readState: { main.state() }, pause: { usleep(50) })
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
        if ProcessInfo.processInfo.environment["NOBORDER_DUMP_SCRIPT"] == "1" {
            let url = URL(fileURLWithPath: "/tmp/noborder-script-\(codeBase).hex")
            let text = code.map { String(format: "%08x", $0) }.joined() + "\n"
                + data.map { String(format: "%02x", $0) }.joined() + "\n"
            try? text.write(to: url, atomically: true, encoding: .ascii)
            NSLog("noborder: script dump at \(url.path) code=\(code.count)w data=\(data.count)B at=\(dataAt) codeBytes=\(codeBytes)")
        }
        return vm_protect(task.port, vm_address_t(codeBase), vm_size_t(codeBytes), 0, executable) == KERN_SUCCESS
    }

    private func write(bytes: UnsafeRawPointer, count: Int, at address: UInt64) -> Bool {
        vm_write(task.port, vm_address_t(address), vm_offset_t(bitPattern: bytes),
                 mach_msg_type_number_t(count)) == KERN_SUCCESS
    }
}
