import Foundation
import NoBorderNative

let usage = "usage: noborder-probe taskport|mainthread|park|threadinfo|runstate <pid> | run <pid> <wid> applied|restored|buttons-hidden|key|noop [fault] | run-repeat <pid> <wid> <mode> <count> | apply|restore <pid> <wid>… | agent-ping <pid> <port-name> | agent-install <pid> | agent-install-fault <pid> | agent-dump <pid> <hex-base> | agent-portinfo <pid> <hex-name> | agent-code <pid> <hex-base> <words> (rendezvous: noborder-tool <pid> [count])"
let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[2]) else {
    print(usage)
    exit(2)
}

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func describe(address: UInt64) -> String {
    guard let pointer = UnsafeRawPointer(bitPattern: Int(truncatingIfNeeded: address)) else { return String(address, radix: 16) }
    var info = Dl_info()
    guard dladdr(pointer, &info) != 0, let name = info.dli_sname else { return String(address, radix: 16) }
    return "\(String(cString: name))+\(address - UInt64(bitPattern: Int64(Int(bitPattern: info.dli_saddr))))"
}

func describe(_ result: RunResult) -> String {
    switch result {
    case .ok: return "ok"
    case .notParked: return "not-parked"
    case .timedOut: return "timed-out"
    case .faulted: return "faulted"
    case .failed: return "failed"
    }
}

func probeScript(mode: String, wid: UInt32, fault: Bool) -> RemoteScript? {
    var script: RemoteScript
    switch mode {
    case "applied": script = RemoteScript.applied(windowNumbers: [wid])
    case "restored": script = RemoteScript.restored(windowNumbers: [wid])
    case "buttons-hidden": script = RemoteScript.applied(windowNumbers: [wid], buttonsHidden: true)
    case "key": script = RemoteScript.keyStateRead(windowNumbers: [wid])
    case "noop": script = RemoteScript.appKitProbe()
    default: return nil
    }
    script.forceFaultForTesting = fault
    return script
}


let task: TargetTask
do {
    task = try TargetTask(pid: pid)
} catch TargetTaskError.denied(let p) {
    fail("\(args[1]) \(p) denied")
} catch TargetTaskError.notFound(let p) {
    fail("\(args[1]) \(p) not-found")
} catch {
    fail("\(args[1]) \(pid) error: \(error)")
}

// The rendezvous client is noborder-tool, not this binary. Byte-identical 0x13 sends
// (MACH_MSGH_BITS(COPY_SEND, PORT_NONE)) answer kr 0 from the tool and
// MACH_SEND_INVALID_DEST 0x10000010 from the probe, deterministically, with identical
// messages and port state — an OBSERVED binary-shape-dependent discrepancy, kernel
// mechanism uncharacterized (full measured family matrix in
// .superpowers/sdd/2026-10-20-noborder-dispatch-entry/progress.md; thread/
// task_swap_mach_voucher are KERN_NOT_SUPPORTED stubs on macOS 15, so no voucher
// manipulation explains it). The install verbs here install, inspect, and report; the
// rendezvous runs in tests via build/noborder-tool.
switch args[1] {
case "taskport":
    print("taskport \(pid) ok")
case "mainthread":
    guard let main = task.mainThread() else { fail("mainthread \(pid) none") }
    print("mainthread \(pid) \(main.id)")
case "park":
    guard let main = task.mainThread() else { fail("park \(pid) no-main-thread") }
    switch task.parkState(of: main) {
    case .parked: print("park \(pid) parked")
    case .running: print("park \(pid) running")
    case .unknown: print("park \(pid) unknown")
    }
case "threadinfo":
    // What the kernel says about the app's main thread. A parked run loop reports run_state=3
    // (TH_WAIT) with its pc inside mach_msg2_trap — which is why the executor has to end that
    // system call to get the thread to run anything at all.
    guard let main = task.mainThread() else { fail("threadinfo \(pid) no-main-thread") }
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(main.port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS, let state = main.state() else { fail("threadinfo \(pid) kr=\(kr)") }
    print("threadinfo \(pid) run_state=\(info.run_state) flags=\(info.flags) pc=\(describe(address: state.__pc))")
case "runstate":
    // The entry gate's input: the kernel's own answer about the thread. 3 (TH_WAIT) is the parked
    // run loop; a thread that has woken and is running app code is not 3, and the state read a
    // moment earlier is no longer the state that thread has.
    guard let main = task.mainThread() else { fail("runstate \(pid) no-main-thread") }
    guard let state = main.runState() else { fail("runstate \(pid) unreadable") }
    print("runstate \(pid) \(state)")
case "run":
    guard args.count >= 5, args.count <= 6, let wid = UInt32(args[3]) else { print(usage); exit(2) }
    if args.count == 6, args[5] != "fault" { print(usage); exit(2) }
    guard let script = probeScript(mode: args[4], wid: wid, fault: args.count == 6) else { print(usage); exit(2) }
    guard let addresses = AddressTable.current() else { fail("run \(pid) no-addresses") }
    guard let main = task.mainThread() else { fail("run \(pid) no-main-thread") }
    let executor = RemoteExecutor(task: task)
    let (result, stopNanoseconds) = executor.run(script, on: main, addresses: addresses)
    var line = "result=\(describe(result)) stop_us=\(stopNanoseconds / 1000)"
    if case .failed(let reason) = result { line += " reason=\(reason)" }
    // The answer word is only trustworthy once the run completed: before the flag it says nothing.
    if script.keyStateRead, result == .ok, let word = executor.lastResultWord { line += " word=\(word)" }
    if let absorbKr = executor.lastAbsorbKr { line += " absorb_kr=0x\(String(absorbKr, radix: 16))" }
    print(line)
    exit(result == .ok ? 0 : 1)
case "run-repeat":
    // Tests only: repeated entries on ONE executor, in one process — the quarantine's domain,
    // which a per-process executor (each probe run) can never show. With NOBORDER_NOQUEUE=1 the
    // first entry runs out its stop limit and quarantines the target for this executor's life:
    // every later entry must answer not-parked immediately, with the target untouched.
    guard args.count >= 6, let wid = UInt32(args[3]), let count = Int(args[5]), count > 0, count <= 2000 else { print(usage); exit(2) }
    guard let script = probeScript(mode: args[4], wid: wid, fault: false) else { print(usage); exit(2) }
    guard let addresses = AddressTable.current() else { fail("run-repeat \(pid) no-addresses") }
    guard let main = task.mainThread() else { fail("run-repeat \(pid) no-main-thread") }
    let executor = RemoteExecutor(task: task)
    var first: RunResult = .notParked
    for n in 1...count {
        let (result, stopNanoseconds) = executor.run(script, on: main, addresses: addresses)
        print("run-repeat \(pid) n=\(n) result=\(describe(result)) stop_us=\(stopNanoseconds / 1000)")
        if n == 1 { first = result }
    }
    exit(first == .timedOut ? 0 : 1)
case "apply", "restore":
    // The engine, one batch of windows in one process. What it decided is on stdout as log lines;
    // the exit code says whether the batch was applied, which is all a caller outside the test needs.
    let numbers = args.dropFirst(3).compactMap { UInt32($0) }
    guard numbers.count == args.count - 3 else { print(usage); exit(2) }
    let verb = args[1] == "apply" ? "applying" : "restoring"
    var lines: [String] = []
    let engine = NativeEngine(log: { print($0); lines.append($0) })
    if args[1] == "apply" { engine.apply(pid: pid, windows: numbers, buttonsHidden: false) } else { engine.restore(pid: pid, windows: numbers) }
    engine.shutdown()
    exit(lines.contains { $0.hasPrefix(verb) } ? 0 : 1)
case "agent-engine":
    // The app's engine class (AgentEngine) driven directly: apply/restore for the given
    // windows; prints the per-window answer. The integration gate for the blob transport.
    guard args.count > 3 else { fail("agent-engine <pid> <wid>… apply|restore [buttons]") }
    let verb = args.last == "buttons" ? args[args.count - 2] : args.last!
    guard ["apply", "restore"].contains(verb) else { fail("agent-engine <pid> <wid>… apply|restore [buttons]") }
    let numbers = args.dropFirst(2).dropLast(verb == "buttons" ? 2 : 1).compactMap { UInt32($0) }
    let buttons = args.last == "buttons"
    let engine = AgentEngine()
    if verb == "apply" {
        for wid in numbers {
            let again = engine.apply(pid: pid, windows: [wid], buttonsHidden: buttons)
            print("agent-engine \(pid) wid=\(wid) apply " + (again.isEmpty ? "changed" : "again"))
        }
    } else {
        for wid in numbers {
            let again = engine.restore(pid: pid, windows: [wid])
            print("agent-engine \(pid) wid=\(wid) restore " + (again.isEmpty ? "changed" : "again"))
        }
    }
    engine.shutdown()
case "agent-install":
    // P1a blob install: the installer writes the two pages (code RX, state RW) and runs the
    // entry as a dispatched block under the fault guard; the pages stay mapped, owned by no
    // one, for the host's lifetime. entryDone is the block's flag (the entry returned);
    // ready is the blob's publication slot — the two are deliberately separate facts.
    // The gate here is the install; the rendezvous is noborder-tool's job.
    let install = AgentInstaller(task: task).install(pid: UInt64(pid), forceFault: false)
    if let reason = install.failure { fail("agent-install \(pid) refused: \(reason)") }
    if let report = install.report {
        print("agent-install \(pid) result=\(describe(report.result)) entryDone=\(report.entryDone) "
              + "ready=\(report.ready.map(String.init) ?? "nil") err=\(report.err.map(String.init) ?? "nil") "
              + "base=0x" + String(report.base, radix: 16) + " serviceName=\(report.serviceName) "
              + "stop_us=\(report.stopNanoseconds / 1000)")
        exit(report.ready == 1 ? 0 : 1)
    }
case "agent-install-fault":
    // The fault-absorb gate: the entry's first act is a jump to address 1. The fault guard
    // must catch it, `ready` must stay 0, and the host must keep running (the test proves
    // that by pinging its windows afterwards).
    let installFault = AgentInstaller(task: task).install(pid: UInt64(pid), forceFault: true)
    if let reason = installFault.failure { fail("agent-install-fault \(pid) refused: \(reason)") }
    if let report = installFault.report {
        print("agent-install-fault \(pid) result=\(describe(report.result)) entryDone=\(report.entryDone) "
              + "ready=\(report.ready.map(String.init) ?? "nil") err=\(report.err.map(String.init) ?? "nil") "
              + "base=\(describe(address: report.base))")
        guard report.result == .faulted, report.ready == 0 else { exit(1) }
        exit(0)
    }
case "agent-uninstall":
    // P1d removal: the dispatched block invalidates the agent's port and releases the
    // source, then the pages are deallocated (nothing can execute on them after that).
    guard args.count > 3, let base = UInt64(args[3], radix: 16) else { fail("agent-uninstall \(pid) wants a hex base") }
    let removal = AgentInstaller(task: task).remove(pid: UInt64(pid), base: base)
    print("agent-uninstall \(pid) result=\(describe(removal.result)) stop_us=\(removal.stopNanoseconds / 1000)"
          + (removal.failure.map { " failure=\($0)" } ?? ""))
    exit(removal.failure == nil ? 0 : 1)
case "agent-dump":
    // Debug: read the installed blob's state slots back (needs the base from agent-install).
    guard args.count > 3, let base = UInt64(args[3], radix: 16) else { fail("agent-dump \(pid) wants a hex base") }
    let dump = AgentInstaller(task: task).dumpState(base: base)
    print("agent-dump \(pid) base=0x" + String(base, radix: 16) + " "
          + dump.map { "\($0.0)=" + ($0.1.map { "0x" + String($0, radix: 16) } ?? "nil") }
                .joined(separator: " "))
case "agent-rows":
    // Debug: the op table's rows (generations, flags, captured originals).
    guard args.count > 3, let base = UInt64(args[3], radix: 16) else { fail("agent-rows \(pid) wants a hex base") }
    for line in AgentInstaller(task: task).dumpRows(base: base) { print(line) }
case "agent-portinfo":
    // Debug: the kernel's view of an installed blob's CFMachPort name (a target-space name, from
    // agent-dump's agentPort): msgcount = queue depth, srights/sorights/mscount, pdrequest.
    guard args.count > 3, let name = UInt32(args[3], radix: 16) else { fail("agent-portinfo \(pid) wants a hex name") }
    typealias GAFn = @convention(c) (mach_port_name_t, mach_port_name_t, mach_port_flavor_t, UnsafeMutableRawPointer, UnsafeMutablePointer<mach_msg_type_number_t>) -> Int32
    guard let gaSym = dlsym(dlopen(nil, RTLD_LAZY), "mach_port_get_attributes") else { fail("agent-portinfo \(pid) no mach_port_get_attributes") }
    let ga = unsafeBitCast(gaSym, to: GAFn.self)
    var pbuf = [UInt32](repeating: 0, count: 10)
    var pcnt = mach_msg_type_number_t(10)
    let pkr = pbuf.withUnsafeMutableBytes { b in ga(task.port, name, mach_port_flavor_t(MACH_PORT_RECEIVE_STATUS), b.baseAddress!, &pcnt) }
    print("agent-portinfo \(pid) name=0x" + String(name, radix: 16) + " kr=\(pkr) "
          + "seqno=\(pbuf[1]) mscount=\(pbuf[2]) qlimit=\(pbuf[3]) msgcount=\(pbuf[4]) "
          + "sorights=\(pbuf[5]) srights=\(pbuf[6]) pdrequest=\(pbuf[7]) nsrequest=\(pbuf[8]) "
          + "flags=0x" + String(pbuf[9], radix: 16))
case "agent-code":
    // Debug: read the installed blob's code words back (hex, word indexes from the code page).
    guard args.count > 4, let base = UInt64(args[3], radix: 16), let count = Int(args[4]) else {
        fail("agent-code \(pid) wants a hex base and a word count")
    }
    let code = AgentInstaller(task: task).dumpCode(base: base, words: count)
    print("agent-code \(pid) " + code.enumerated().map { i, w in
        "\(i):" + (w.map { String(format: "%08x", $0) } ?? "nil")
    }.joined(separator: " "))
case "agent-addrs":
    // Debug: the two tables the installer feeds the blob — the executor's stub addresses and
    // the blob's own dlsym'd set, as THIS process resolves them.
    guard let exec = AddressTable.current(), let agent = AgentAddresses.current() else { fail("agent-addrs \(pid) no-addresses") }
    print("exec: " + Mirror(reflecting: exec).children.map { "\($0.label ?? "?")=" + String(format: "%016x", $0.value as! UInt64) }.joined(separator: " "))
    print("agent: " + agent.table.map { String(format: "%016x", $0) }.joined(separator: " "))
case "agent-install-planted":
    // Sandbox rendezvous proof: install with a controller-planted receive port (no bootstrap), then
    // ping the blob over the extracted send right and confirm the blob's callback counter advances —
    // proving the planted channel delivers. This verifies the load-bearing primitive (allocate a
    // receive right in the target, extract MAKE_SEND → kr 0) end to end.
    let installP = AgentInstaller(task: task).install(pid: UInt64(pid), plantPort: true)
    if let reason = installP.failure { fail("agent-install-planted \(pid) refused: \(reason)") }
    guard let report = installP.report else { fail("agent-install-planted \(pid): no report") }
    let base = report.base
    let inst = AgentInstaller(task: task)
    func stateWord(_ slot: Int) -> UInt64 { inst.readSlot(base: base, slot) ?? .max }
    let planted = stateWord(AgentBlob.plantedPortSlot)
    print("agent-install-planted \(pid) ready=\(report.ready.map(String.init) ?? "nil") "
          + "err=\(report.err.map(String.init) ?? "nil") base=0x" + String(base, radix: 16)
          + " ctrlSend=\(report.ctrlSend) plantedPort=\(planted)")
    guard report.ready == 1, report.ctrlSend != 0 else {
        _ = AgentInstaller(task: task).remove(pid: UInt64(pid), base: base)
        fail("agent-install-planted \(pid): not live via the planted path")
    }
    // Ping the blob over the extracted send right (40 B: header 24 + seq 8 + counter 8, id 2001).
    let before = stateWord(AgentBlob.counterSlot)
    var pings = 3
    for seq in 1...pings {
        var msg = [UInt8](repeating: 0, count: 40)
        func f32(_ at: Int, _ v: UInt32) { for i in 0..<4 { msg[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
        func f64(_ at: Int, _ v: UInt64) { for i in 0..<8 { msg[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
        f32(0, 0x13)                 // msgh_bits: COPY_SEND in the remote field
        f32(4, 40)                   // msgh_size
        f32(8, report.ctrlSend)      // msgh_remote_port = the planted channel
        f32(20, 2001)                // msgh_id = ping
        f64(24, UInt64(seq))
        let kr = msg.withUnsafeMutableBytes { b in
            mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                     40, 0, mach_port_name_t(MACH_PORT_NULL), 100, 0)
        }
        if kr != KERN_SUCCESS { print("  ping \(seq) send kr=\(kr)"); pings -= 1 }
        usleep(50_000)
    }
    usleep(200_000)
    let after = stateWord(AgentBlob.counterSlot)
    print("agent-install-planted \(pid) counter \(before) -> \(after) (pings=\(pings))")
    _ = AgentInstaller(task: task).remove(pid: UInt64(pid), base: base)
    exit(after > before ? 0 : 1)
case "agent-ping":
    // P1a-0 (kept for the record): the extract-right handoff is DEAD on macOS 15 —
    // mach_port_extract_right on a target-allocated name returns KERN_INVALID_CAPITAL (18),
    // measured 2026-10-20, so this path cannot get a send right and never pings.
    // tests/agent.sh drives the live shape: noborder-tool.
    fail("agent-ping \(pid) extract-right is dead on this OS (kr 18); use noborder-tool")
default:
    print(usage)
    exit(2)
}

