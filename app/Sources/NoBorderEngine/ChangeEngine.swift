import Darwin

/// One engine that changes windows.
///
/// `apply` and `restore` take the windows of one process in one call, because that is one stop in
/// that app's main thread: a batch is applied as one call script, so a window is never half-changed
/// by a batch that stops halfway. Nothing here returns a result — the caller is a timer, and what it
/// can do about a target it cannot reach is try again on the next scan.
public protocol ChangeEngine: AnyObject {
    /// Make these windows of one process show the change, in one stop.
    ///
    /// Returns the windows the engine did **not** change and the caller should ask for again. A
    /// process whose main thread is not parked is the only normal case: the app is busy, and a
    /// window of its is deferred, never dropped — it stays as it is and is asked for on a later
    /// scan. Anything else the engine cannot use (a fault, a target with no task port, no AppKit)
    /// is reported and left alone, because asking again would ask for the same failure.
    ///
    /// The caller needs the answer, not the log line: it has already written these windows off as
    /// changed, and a window the engine never touched has to be handed back or it is never changed.
    ///
    /// `buttonsHidden` is the app's current option: applied windows show the buttons or not as it
    /// says, and a window that is already applied and needs only the option changed is applied again
    /// with the new value.
    @discardableResult
    func apply(pid: pid_t, windows: [UInt32], buttonsHidden: Bool) -> [UInt32]

    /// Put these windows of one process back, in one stop. Same contract as `apply`.
    @discardableResult
    func restore(pid: pid_t, windows: [UInt32]) -> [UInt32]

    /// Release everything held on other processes: their task ports, their scratch memory.
    func shutdown()
}
