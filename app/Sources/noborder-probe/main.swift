import Foundation
import NoBorderEngine

let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[2]) else {
    print("usage: noborder-probe taskport <pid>")
    exit(2)
}

switch args[1] {
case "taskport":
    do {
        let task = try TargetTask(pid: pid)
        print("taskport \(pid) ok")
        task.close()
        exit(0)
    } catch TargetTaskError.denied(let p) {
        print("taskport \(p) denied")
    } catch TargetTaskError.notFound(let p) {
        print("taskport \(p) not-found")
    } catch {
        print("taskport \(pid) error: \(error)")
    }
    exit(1)
default:
    print("usage: noborder-probe taskport <pid>")
    exit(2)
}
