import Foundation

/// What the menu says about the scan loop.
///
/// Small on purpose. The loop runs in this process, so these are the states a loop has: not running
/// and running. Stopping restores what was changed, and the restore blocks the main thread, so no
/// menu ever renders a state between running and off. The daemon this replaces had a child
/// process to supervise,
/// so it also had starting, crashed, restarting and a fatal setup failure — an Xcode that couldn't
/// load, a script missing from the bundle, a Python that exited. None of those exist here: there is
/// no process, no debugger, no Xcode and nothing to request at startup, so a state for them would be
/// a state nothing can enter.
public enum EngineStatus: Equatable {
    case off
    case running(windows: Int)

    public var menuText: String {
        switch self {
        case .off: return "Off"
        case .running(let n):
            switch n {
            case 0: return "Running: no windows changed"
            case 1: return "Running: 1 window changed"
            default: return "Running: \(n) windows changed"
            }
        }
    }
}
