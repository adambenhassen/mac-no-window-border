import Foundation
import NoBorderEngine
import NoBorderLogic
import NoBorderNative

// A scoped end-to-end harness: the real ScanLoop + AgentEngine against ONE window of ONE
// process (a tests/hostapp instance), never a machine-wide scan. It is how the focus-kick
// re-apply is tested without the GUI: SIGUSR1 stands in for the NSWorkspace activation
// notification the shipped app listens to (EngineManager wires that to `loop.kick()`), so a
// driver can apply, let the target repaint its border back, kick, and read the window's pixels.
// SIGTERM runs the loop's stop (restore + remove the agent), as the app's quit does.
let a = CommandLine.arguments
guard a.count >= 3, let pid = Int32(a[1]), let wid = UInt32(a[2]) else {
    FileHandle.standardError.write(Data("usage: noborder-e2e <pid> <wid>\n".utf8))
    exit(2)
}
func emit(_ s: String) { print(s); fflush(stdout) }

/// Wraps the real engine so every apply/restore is visible, with the deferred result — the agent's
/// own log dedups by (pid, outcome), which would hide a second, kick-driven re-apply. `deferred=[]`
/// means the agent accepted the change; a non-empty list means it was handed back (busy/failed).
final class LoggingEngine: ChangeEngine {
    let inner: ChangeEngine
    init(_ inner: ChangeEngine) { self.inner = inner }
    func apply(pid: pid_t, windows: [UInt32], buttonsHidden: Bool) -> [UInt32] {
        let again = inner.apply(pid: pid, windows: windows, buttonsHidden: buttonsHidden)
        emit("APPLY \(pid) \(windows) deferred=\(again)")
        return again
    }
    func restore(pid: pid_t, windows: [UInt32]) -> [UInt32] {
        let again = inner.restore(pid: pid, windows: windows)
        emit("RESTORE \(pid) \(windows) deferred=\(again)")
        return again
    }
    func keyWindows(pid: pid_t, windows: [UInt32]) -> [UInt32: Bool] {
        emit("KEYREAD \(pid) \(windows)")
        return inner.keyWindows(pid: pid, windows: windows)
    }
    func shutdown() { inner.shutdown() }
}

let engine = LoggingEngine(AgentEngine(log: { emit("engine: \($0)") }))
// No settle: the harness drives one window it already knows is maximized, and the settle only
// guards a drag — which a single fixed window never is. A large key-read floor keeps the timer
// path from reading again during the test, so a KEYREAD after the kick could only be the kick's
// own read — which the fix no longer does (that is exactly what tests/focus.sh asserts).
let tracker = WindowTracker(applySettle: 0, restoreSettle: 0)
var announced = false
let loop = ScanLoop(
    scan: { [ScannedWindow(wid: wid, pid: pid, maximized: true)] },
    tracker: tracker,
    engine: engine,
    keyReadInterval: 3600,
    log: { emit("loop: \($0)") },
    status: { n in if n >= 1 && !announced { announced = true; emit("APPLIED") } }
)

// SIGUSR1 = a focus kick (the activation notification the app turns into `loop.kick()`).
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler { emit("KICK"); loop.kick() }
usr1.resume()
signal(SIGUSR1, SIG_IGN)
// SIGTERM = quit: stop the loop (restore the window, remove the agent), then leave.
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { loop.stop(); emit("STOPPED"); exit(0) }
term.resume()
signal(SIGTERM, SIG_IGN)

emit("START pid=\(pid) wid=\(wid)")
loop.start()
dispatchMain()
