import Darwin

public enum TargetTaskError: Error {
    case denied(pid: Int32)
    case notFound(pid: Int32)
}

/// A task port for another process. Getting one needs the com.apple.security.cs.debugger
/// entitlement: unsigned, task_for_pid returns KERN_FAILURE (see tests/probe.sh).
public final class TargetTask {
    public let pid: Int32
    public private(set) var port: mach_port_t = 0

    public init(pid: Int32) throws {
        self.pid = pid
        if kill(pid, 0) != 0 && errno == ESRCH { throw TargetTaskError.notFound(pid: pid) }
        // Our own process: the kernel's self-task reference carries the rights `task_for_pid`
        // withholds from a signed binary (a task ref it returns cannot vm_read the target).
        if pid == getpid() { port = mach_task_self_; return }
        var task: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &task)
        guard kr == KERN_SUCCESS, task != 0 else { throw TargetTaskError.denied(pid: pid) }
        port = task
    }

    deinit { close() }

    public func close() {
        guard port != 0, port != mach_task_self_ else { return }
        mach_port_deallocate(mach_task_self_, port)
        port = 0
    }
}
