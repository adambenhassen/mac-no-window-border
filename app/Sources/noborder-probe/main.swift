import Foundation
import NoBorderEngine

let usage = "usage: noborder-probe taskport|mainthread|park|threadinfo <pid> | run <pid> <wid> applied|restored [fault] | apply|restore <pid> <wid>…"
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
case "run":
    guard args.count >= 5, args.count <= 6, let wid = UInt32(args[3]) else { print(usage); exit(2) }
    if args.count == 6, args[5] != "fault" { print(usage); exit(2) }
    var script: RemoteScript
    switch args[4] {
    case "applied": script = RemoteScript.applied(windowNumbers: [wid])
    case "restored": script = RemoteScript.restored(windowNumbers: [wid])
    default: print(usage); exit(2)
    }
    script.forceFaultForTesting = args.count == 6
    guard let addresses = AddressTable.current() else { fail("run \(pid) no-addresses") }
    guard let main = task.mainThread() else { fail("run \(pid) no-main-thread") }
    let (result, stopNanoseconds) = RemoteExecutor(task: task).run(script, on: main, addresses: addresses)
    var line = "result=\(describe(result)) stop_us=\(stopNanoseconds / 1000)"
    if case .failed(let reason) = result { line += " reason=\(reason)" }
    print(line)
    exit(result == .ok ? 0 : 1)
case "apply", "restore":
    // The engine, one batch of windows in one process. What it decided is on stdout as log lines;
    // the exit code says whether the batch was applied, which is all a caller outside the test needs.
    let numbers = args.dropFirst(3).compactMap { UInt32($0) }
    guard numbers.count == args.count - 3 else { print(usage); exit(2) }
    let verb = args[1] == "apply" ? "applying" : "restoring"
    var lines: [String] = []
    let engine = NativeEngine(log: { print($0); lines.append($0) })
    if args[1] == "apply" { engine.apply(pid: pid, windows: numbers) } else { engine.restore(pid: pid, windows: numbers) }
    engine.shutdown()
    exit(lines.contains { $0.hasPrefix(verb) } ? 0 : 1)
default:
    print(usage)
    exit(2)
}
