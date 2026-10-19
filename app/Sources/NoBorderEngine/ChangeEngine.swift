import Darwin

/// One engine that changes windows: the legacy Python/LLDB daemon behind it, or the native one.
///
/// `apply` and `restore` take the windows of one process in one call, because that is one stop in
/// that app's main thread: a batch is applied as one call script, so a window is never half-changed
/// by a batch that stops halfway. Nothing here returns a result — the caller is a timer, and what it
/// can do about a target it cannot reach is try again on the next scan.
public protocol ChangeEngine: AnyObject {
    func apply(pid: pid_t, windows: [UInt32])
    func restore(pid: pid_t, windows: [UInt32])
    /// Release everything held on other processes: their task ports, their scratch memory.
    func shutdown()
}
