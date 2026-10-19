import Foundation
import NoBorderEngine

let usage = "usage: noborder-probe taskport|mainthread|park <pid>"
let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[2]) else {
    print(usage)
    exit(2)
}

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
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
default:
    print(usage)
    exit(2)
}
