import Foundation

/// Installs an `AgentBlob` into a cooperative target: resolve the tables, allocate the two pages,
/// write them, split the protections, run the entry as a dispatched block under the fault guard,
/// and read the blob's own report back. The pages are the installer's, allocated outside the
/// `RemoteExecutor`'s scratch ownership — the executor frees its own regions when its flag
/// flips, and a resident agent's code and state must survive that, every later run, and the
/// installer's own exit (verdict 6: resident lifetime explicit).
///
/// The READY boundary is the installer returning with the entry done, plus the first ping the
/// tool ACKs — the tool's side of that is the caller's; this answers the entry's facts:
/// `entryDone` (the dispatched block's flag: the entry returned) and the blob's `ready` slot
/// (it published). They are deliberately separate: a checked registration failure completes
/// with `entryDone` true and `ready` zero and `err` naming the kr, and a fault inside the
/// publication can leave anything (verdict 6: "no source on fault" is not a guarantee the
/// absorber can give — publication is not transactional, so the gate reads all three).
public final class AgentInstaller {
    private let task: TargetTask

    public struct Report {
        /// The dispatched entry's completion: the executor's answer for the block running the
        /// blob's entry (`.faulted` means the absorber caught it; `entryDone` is then false).
        public var result: RunResult
        public var entryDone: Bool
        public var ready: UInt64?
        public var err: UInt64?
        public var base: UInt64
        public var stopNanoseconds: Int
        /// The service name this install registered (the nonce prefix + the pid's digits) —
        /// the client looks THIS up, not the pid convention: the old registration outlives
        /// removal, so the name is a per-install fact, not a per-pid one.
        public var serviceName: String
    }

    public init(task: TargetTask) { self.task = task }

    /// nil on success; the reason it refused — always before the target was touched, except the
    /// listed post-entry failures, which are the blob's own answers.
    public func install(pid: UInt64, forceFault: Bool = false, stopLimit: TimeInterval = 2.0)
        -> (report: Report?, failure: String?) {
        // Resolve everything before touching the target: a blob we cannot finish is a blob we
        // never started (verdict 5's build order).
        guard let addresses = AgentAddresses.current() else { return (nil, "no-agent-addresses") }
        guard let execAddresses = AddressTable.current() else { return (nil, "no-exec-addresses") }
        guard let arch = Self.architecture(of: pid_t(truncatingIfNeeded: pid)) else { return (nil, "unreadable-executable") }
        guard arch == .arm64 else {
            return (nil, arch == .arm64e ? "arm64e-target-refused" : "not-arm64")
        }
        guard let path = Self.executablePath(pid_t(truncatingIfNeeded: pid)) else {
            return (nil, "unreadable-executable-path")
        }
        guard !Self.isPlatformPath(path) else { return (nil, "platform-target-refused") }
        guard let main = task.mainThread() else { return (nil, "no-main-thread") }

        let namePrefix = Self.namePrefix()
        let blob = AgentBlob.build(pid: pid, forceFault: forceFault, namePrefix: namePrefix)
        var state = blob.state
        func put(_ at: Int, _ value: UInt64) {
            var word = value
            for i in 0..<8 { state[at + i] = UInt8(word & 0xff); word >>= 8 }
        }

        var address: vm_address_t = 0
        let kr = vm_allocate(task.port, &address, vm_size_t(AgentBlob.regionBytes), 1)
        guard kr == KERN_SUCCESS else { return (nil, "vm_allocate kr=\(kr)") }
        let base = UInt64(address)
        put(AgentBlob.cbAddrSlot, base &+ UInt64(blob.cbOff))
        put(AgentBlob.timerCbAddrSlot, base &+ UInt64(blob.timerOff))
        for (index, value) in addresses.table.enumerated() {
            put(AgentBlob.tableSlot + 8 * index, value)
        }

        // The region is writable from `vm_allocate`; write both pages, then split: the code page
        // RX (the all-RX writer's problem — writable state needs its own page, verdict 5), the
        // state page RW. Instruction-cache coherency is the property every remote write on this
        // OS already relies on: cross-task `vm_write` pages execute coherently (the shipped
        // executor's whole test history; the entry's first ping ACK is this install's proof).
        guard write(blob.code, at: base), write(state, at: base &+ UInt64(AgentBlob.pageSize)) else {
            vm_deallocate(task.port, address, vm_size_t(AgentBlob.regionBytes))
            return (nil, "vm_write failed")
        }
        let codeProtect = vm_protect(task.port, address, vm_size_t(AgentBlob.pageSize), 0,
                                     VM_PROT_READ | VM_PROT_EXECUTE)
        let stateProtect = vm_protect(task.port, address &+ vm_address_t(AgentBlob.pageSize),
                                      vm_size_t(AgentBlob.pageSize), 0, VM_PROT_READ | VM_PROT_WRITE)
        guard codeProtect == KERN_SUCCESS, stateProtect == KERN_SUCCESS else {
            vm_deallocate(task.port, address, vm_size_t(AgentBlob.regionBytes))
            return (nil, "vm_protect kr=\(codeProtect)/\(stateProtect)")
        }

        let script = RemoteScript.blobEntry(state: base &+ UInt64(AgentBlob.pageSize), entry: base)
        let executor = RemoteExecutor(task: task)
        let (result, stop) = executor.run(script, on: main, addresses: execAddresses,
                                          stopLimit: stopLimit, enterLimit: 2.0)
        let stateBase = base &+ UInt64(AgentBlob.pageSize)
        let report = Report(result: result, entryDone: result == .ok,
                            ready: task.readWord(at: stateBase &+ UInt64(AgentBlob.readySlot)),
                            err: task.readWord(at: stateBase &+ UInt64(AgentBlob.errSlot)),
                            base: base, stopNanoseconds: stop,
                            serviceName: namePrefix + String(pid))
        if result == .ok || result == .faulted {
            // The thread is back with the app — the install is over, in both directions. The
            // blob's pages stay mapped and protected: they are not the executor's to release.
            return (report, nil)
        }
        // The entry never ran: nothing published, nothing named, so the pages can go.
        vm_deallocate(task.port, address, vm_size_t(AgentBlob.regionBytes))
        return (report, "entry-\(describe(result))")
    }

    /// Remove a resident agent (P1d): run the dispatched invalidation block (CFMachPort
    /// invalidate + releases, in the app's healthy main-queue context), and only after its
    /// completion flag — the run loop can no longer schedule the callback — deallocate the
    /// blob's pages. A fault inside the block resumes at the block epilogue (the dispatched
    /// mode's guard path); the pages then stay mapped, which is the safe half of the failure.
    public func remove(pid: UInt64, base: UInt64) -> (result: RunResult, stopNanoseconds: Int, failure: String?) {
        guard let addresses = AddressTable.current() else { return (.failed("remove-preflight"), 0,"no-exec-addresses") }
        guard let main = task.mainThread() else { return (.failed("remove-preflight"), 0,"no-main-thread") }
        let script = RemoteScript.blobRemove(state: base &+ UInt64(AgentBlob.pageSize))
        let executor = RemoteExecutor(task: task)
        let (result, stop) = executor.run(script, on: main, addresses: addresses,
                                          stopLimit: 2.0, enterLimit: 2.0)
        guard result == .ok else { return (result, stop, "remove-\(describe(result))") }
        let kr = vm_deallocate(task.port, vm_address_t(base), vm_size_t(AgentBlob.regionBytes))
        return (.ok, stop, kr == KERN_SUCCESS ? nil : "vm_deallocate kr=\(kr)")
    }

    /// The state page's named slots, read back from the target (debug: shows how far the entry
    /// got when a install reports `.faulted` — every slot the entry wrote is set, the rest are
    /// the build-time prefill).
    public func dumpState(base: UInt64) -> [(String, UInt64?)] {
        let state = base &+ UInt64(AgentBlob.pageSize)
        let slots: [(String, Int)] = [
            ("magic", AgentBlob.magicSlot), ("version", AgentBlob.versionSlot),
            ("codeLen", AgentBlob.codeLenSlot), ("entryOff", AgentBlob.entryOffSlot),
            ("cbOff", AgentBlob.cbOffSlot), ("cbAddr", AgentBlob.cbAddrSlot),
            ("pid", AgentBlob.pidSlot), ("agentPort", AgentBlob.agentPortSlot),
            ("cbEntries", AgentBlob.cbEntriesSlot), ("dbgSize", AgentBlob.dbgSizeSlot),
            ("srcRef", AgentBlob.srcRefSlot),
            ("toolPort", AgentBlob.toolPortSlot), ("counter", AgentBlob.counterSlot),
            ("ready", AgentBlob.readySlot), ("err", AgentBlob.errSlot),
            ("errHandshake", AgentBlob.errHandshakeSlot), ("errAck", AgentBlob.errAckSlot),
            ("token", AgentBlob.tokenSlot), ("bs", AgentBlob.bsSlot),
            // P1b preflight trail: dbgSize now also carries the entry's x0 (breadcrumb); the
            // cursor slots say which preflight iteration was running; first/last SEL and the
            // class say how far resolution got.
            ("selWindow", AgentBlob.selWindowSlot), ("selResponds", AgentBlob.selRespondsSlot),
            ("nsAppClass", AgentBlob.nsAppClassSlot),
            ("cornerOn", AgentBlob.cornerOnSlot), ("cornerOff", AgentBlob.cornerOffSlot),
            ("depth", AgentBlob.depthSlot), ("wakeTimer", AgentBlob.wakeTimerSlot),
            ("selNameCursor", AgentBlob.selNameCursorSlot),
            ("selStoreCursor", AgentBlob.selStoreCursorSlot),
            ("selLoopCount", AgentBlob.selLoopCountSlot),
        ]
        var out = slots.map { (name, at) in (name, task.readWord(at: state &+ UInt64(at))) }
        func bytes(_ at: Int, _ n: Int) -> String {
            var raw = [UInt8]()
            for word in 0..<(n / 8) {
                guard let v = task.readWord(at: state &+ UInt64(at + word * 8)) else { return "nil" }
                for i in 0..<8 { raw.append(UInt8((v >> (8 * i)) & 0xff)) }
            }
            let name = String(bytes: raw.prefix { $0 != 0 }, encoding: .ascii) ?? "?"
            return "\"" + name + "\""
        }
        out.append(("rzName=" + bytes(AgentBlob.rzNameSlot, 32), nil))
        out.append(("toolName=" + bytes(AgentBlob.toolNameSlot, 32), nil))
        return out
    }

    /// The op table's rows, read back (debug: the row state is the op path's whole memory —
    /// generations, flags, and the captured originals the restore path trusts).
    public func dumpRows(base: UInt64) -> [String] {
        let state = base &+ UInt64(AgentBlob.pageSize)
        var out = [String]()
        for i in 0..<AgentBlob.opTableCount {
            let row = state &+ UInt64(AgentBlob.opTableSlot + i * AgentBlob.opEntryBytes)
            func w(_ at: Int) -> UInt64 { task.readWord(at: row &+ UInt64(at)) ?? .max }
            let wid = w(AgentBlob.rowWid)
            guard wid != 0 || w(AgentBlob.rowFlags) != 0 else { continue }
            let radius = Double(bitPattern: w(AgentBlob.rowOrigRadius))
            out.append("row\(i) wid=\(wid) op=\(w(AgentBlob.rowOp)) desiredGen=\(w(AgentBlob.rowDesiredGen))"
                + " doneGen=\(w(AgentBlob.rowDoneGen)) lastStatus=\(w(AgentBlob.rowLastStatus))"
                + " flags=\(w(AgentBlob.rowFlags)) object=0x" + String(w(AgentBlob.rowObject), radix: 16)
                + " origShadow=\(w(AgentBlob.rowOrigShadow)) origRadius=\(radius)"
                + " origBtn=\(w(AgentBlob.rowOrigButton0)),\(w(AgentBlob.rowOrigButton1)),\(w(AgentBlob.rowOrigButton2))"
                + " origDeco=\(w(AgentBlob.rowOrigDecoration))")
        }
        return out
    }

    /// The code page's words, read back from the target (debug: disassembles what the installer
    /// actually wrote when a build behaves differently than the built blob).
    public func dumpCode(base: UInt64, words: Int) -> [UInt32?] {
        (0..<words).map { index in
            // Read aligned 8-byte words; take the low half for even indexes, the high half for odd.
            guard let word = task.readWord(at: base &+ UInt64(index / 2 * 8)) else { return nil }
            return UInt32(truncatingIfNeeded: index.isMultiple(of: 2) ? word : word >> 32)
        }
    }

    private func write(_ bytes: [UInt8], at address: UInt64) -> Bool {
        bytes.withUnsafeBytes { buffer in
            vm_write(task.port, vm_address_t(address), vm_offset_t(bitPattern: buffer.baseAddress!),
                     mach_msg_type_number_t(buffer.count)) == KERN_SUCCESS
        }
    }

    private func write(_ words: [UInt32], at address: UInt64) -> Bool {
        words.withUnsafeBytes { buffer in
            vm_write(task.port, vm_address_t(address), vm_offset_t(bitPattern: buffer.baseAddress!),
                     mach_msg_type_number_t(buffer.count)) == KERN_SUCCESS
        }
    }

    private func describe(_ result: RunResult) -> String {
        switch result {
        case .ok: return "ok"
        case .notParked: return "not-parked"
        case .timedOut: return "timed-out"
        case .faulted: return "faulted"
        case .failed: return "failed"
        }
    }

    /// The service name's 16-byte prefix: `noborder.rz.` + a 4-character base-62 nonce of the
    /// boot clock, fresh per install. A removed agent's registration stays in the target's
    /// namespace (no `bootstrap_delete` export; measured 2026-10-21), so a fixed name fails
    /// every later install into that process (blob err 0x44d, ready=0) — the nonce makes each
    /// install's name new. The tool and probe keep the `com.noborder.rz.<pid>` convention;
    /// names are per-install facts, and the client looks up the one from its own install.
    static func namePrefix() -> String {
        var n = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var suffix = ""
        for _ in 0..<4 { suffix.append(alphabet[Int(n % 62)]); n /= 62 }
        return "noborder.rz." + suffix
    }

    // MARK: refusing platform targets

    /// XNU's `thread_set_state` policy terminates the injector that rewrites a restricted
    /// target's thread state (codex review 2026-10-21, citing `thread_set_state_allowed` →
    /// `mach_port_guard_exception(MACH_PORT_NULL, 0, kGUARD_EXC_THREAD_SET_STATE)` — the
    /// fatal guard class, not recoverable by an exception handler). Measured 2026-10-21:
    /// the app's scan was SIGKILLed this way (crash 309: "THREAD_SET_STATE on mach port 0
    /// (guarded with 0x0)") while installing, minutes before it, a hardened NON-platform
    /// target (iTerm2) had been entered by the CLI probe with no kill — the restriction is
    /// the target's task policy (platform binaries, mach-hardened opt-ins, `CS_DEBUGGED`),
    /// not `CS_RUNTIME` wholesale.
    ///
    /// The public read of that policy (`csops(CS_OPS_STATUS)`) answers EPERM from Swift
    /// processes on this machine (measured 2026-10-21: EPERM in Swift binaries — linker-
    /// signed and ad-hoc-kill alike — kr=0 from a C harness, entitled and not), so
    /// eligibility is the executable-path test: Apple's system locations are the platform
    /// population, all of it reachable, none of it enterable.
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = UInt32(buffer.count)
        guard let procPidPath,
              buffer.withUnsafeMutableBytes({ pointer in procPidPath(pid, pointer.baseAddress!, size) }) > 0
        else { return nil }
        return String(cString: buffer)
    }

    static func isPlatformPath(_ path: String) -> Bool {
        for prefix in ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/private/etc/"]
        where path.hasPrefix(prefix) { return true }
        return false
    }

    // MARK: refusing arm64e

    private enum Architecture { case arm64, arm64e, other }

    /// The target executable's architecture, from its on-disk Mach header: the blob is plain
    /// arm64, and the signed-pointer calling conventions of arm64e are unvalidated for a
    /// hand-assembled CF callback — refuse, as designed (not attempted this phase).
    /// `proc_pidpath` from libproc — no module import for it, so the same dlsym route the
    /// executor takes for the unexported RPCs.
    private static let procPidPath: (@convention(c) (pid_t, UnsafeMutableRawPointer, UInt32) -> Int32)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_pidpath") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t, UnsafeMutableRawPointer, UInt32) -> Int32).self)
    }()

    private static func architecture(of pid: pid_t) -> Architecture? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let pathSize = UInt32(buffer.count)
        guard let procPidPath,
              buffer.withUnsafeMutableBytes({ pointer in
                  procPidPath(pid, pointer.baseAddress!, pathSize)
              }) > 0 else { return nil }
        guard let file = FileHandle(forReadingAtPath: String(cString: buffer)),
              let data = try? file.read(upToCount: 4096) else { return nil }
        let head = Array(data)
        func word32(_ data: [UInt8], _ at: Int, bigEndian: Bool) -> UInt32 {
            guard at + 4 <= data.count else { return 0 }
            // Index the array, not a slice of it: ArraySlice indices start at `at`, so bytes[0]
            // is only valid when at == 0.
            let b0 = UInt32(data[at]), b1 = UInt32(data[at + 1]), b2 = UInt32(data[at + 2]),
                b3 = UInt32(data[at + 3])
            return bigEndian
                ? b0 << 24 | b1 << 16 | b2 << 8 | b3
                : b3 << 24 | b2 << 16 | b1 << 8 | b0
        }
        // `CPU_SUBTYPE_ARM64E` is 2 with the ABI mask 0xFFFFF000 (<mach/machine.h>) — the
        // old test compared 15, which matches no real subtype, so arm64e headers fell
        // through as plain arm64 (codex review 2026-10-21).
        let arm64: UInt32 = 0x0100_000C, arm64eSubtype: UInt32 = 0x0000_0002, abiMask: UInt32 = 0xFFFF_F000
        func slice(_ data: [UInt8], _ at: Int) -> Architecture? {
            guard word32(data, at, bigEndian: false) == 0xFEED_FACF else { return nil }   // MH_MAGIC_64
            guard word32(data, at + 4, bigEndian: false) == arm64 else { return .other }
            return word32(data, at + 8, bigEndian: false) & abiMask == arm64eSubtype ? .arm64e : .arm64
        }
        if let direct = slice(head, 0) { return direct }
        guard word32(head, 0, bigEndian: true) == 0xCAFE_BABE else { return .other }
        let count = Int(word32(head, 4, bigEndian: true))
        guard count > 0, count < 64 else { return .other }
        for index in 0..<count {
            let arch = 8 + index * 20
            guard word32(head, arch, bigEndian: true) == arm64 else { continue }
            return word32(head, arch + 4, bigEndian: true) & abiMask == arm64eSubtype ? .arm64e : .arm64
        }
        return .other
    }
}
