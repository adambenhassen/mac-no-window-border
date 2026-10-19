import Darwin
import Foundation

/// A window the scan found, reduced to what the tracker decides with: where it is, whose it is, and
/// whether it fills its screen's usable area. The shadow state is not here: the native path never
/// reads the WindowServer tag, so a window has nothing to report about it.
public struct ScannedWindow: Equatable {
    public let wid: UInt32
    public let pid: pid_t
    public let maximized: Bool

    public init(wid: UInt32, pid: pid_t, maximized: Bool) {
        self.wid = wid
        self.pid = pid
        self.maximized = maximized
    }
}

/// What one scan asks for: windows to change and windows to put back, each grouped by the process
/// that owns it. One batch per process is one stop in that app's main thread, which is what keeps a
/// window from being half-changed by a batch that stops halfway.
public struct TrackerDecision: Equatable {
    public var apply: [pid_t: [UInt32]]
    public var restore: [pid_t: [UInt32]]

    public init(apply: [pid_t: [UInt32]] = [:], restore: [pid_t: [UInt32]] = [:]) {
        self.apply = apply
        self.restore = restore
    }
}

/// Which windows are ours to change, and when to change them.
///
/// The port of `windowstate.py`'s `Tracker` without the three things the native path has no use for:
/// the no-shadow tag and its untag (the changes are made inside the app, and are not a WindowServer
/// tag), the 2 s → 2 min backoff for a tag a window keeps putting back, and the launch grace for
/// young processes. What is kept is the part that is about user-visible behaviour:
///
/// - a window has to fill the usable area for `applySettle` before it is changed, and stop filling it
///   for `restoreSettle` before it is put back, so a drag is never fought over;
/// - only a window in `applied` is ever restored — we undo our own changes and nothing else;
/// - a window that leaves the screen keeps its record: the app may have undone our change while we
///   could not see it, and when the window comes back it is still ours.
///
/// `update` is called once per scan with the whole screen, at a time the caller supplies, so a settle
/// is a thing the tests can drive. Nothing here talks to a process; the caller hands each decision to
/// an engine, and a window whose app is busy simply stays in the state it is in until the next scan.
public final class WindowTracker {
    private let applySettle: TimeInterval
    private let restoreSettle: TimeInterval
    private let maxRecords: Int

    /// wid -> the process whose window we changed. The record of a change we owe the user: only a
    /// window in here is ever restored, and it is restored to the process recorded here, not to
    /// whoever owns that window number now.
    private var applied: [UInt32: pid_t] = [:]

    /// wid -> (the state it has to keep for the settle to end, the moment it started keeping it).
    private var pending: [UInt32: (state: Bool, since: TimeInterval)] = [:]

    public init(applySettle: TimeInterval = 0.5, restoreSettle: TimeInterval = 0.5, maxRecords: Int = 4096) {
        self.applySettle = applySettle
        self.restoreSettle = restoreSettle
        self.maxRecords = maxRecords
    }

    /// The number of windows we have changed and not put back.
    public var appliedCount: Int { applied.count }

    /// The engine did not apply these windows, so we have not changed them: forget the records. The
    /// next scan sees a maximized window we do not own, settles for the apply settle, and asks again
    /// — which is the whole of "deferred, never dropped", and the settle is the backoff.
    public func undoApply(_ windows: [UInt32]) {
        for wid in windows {
            applied.removeValue(forKey: wid)
            pending.removeValue(forKey: wid)
        }
    }

    /// The engine did not restore these windows, so they are still showing our change: put the records
    /// back. A window we have changed and failed to put back is the Phase 1 "windows left changed"
    /// outcome, which the Phase 2 spec says must not exist; the next scan asks again.
    public func undoRestore(_ windows: [UInt32], of pid: pid_t) {
        for wid in windows {
            applied[wid] = pid
            pending.removeValue(forKey: wid)
        }
    }

    public func update(windows: [ScannedWindow], at now: TimeInterval) -> TrackerDecision {
        var decision = TrackerDecision()
        var seen: Set<UInt32> = []
        for window in windows {
            seen.insert(window.wid)
            let isOurs = applied[window.wid] != nil
            if window.maximized == isOurs {
                // Nothing to do: un-maximized and not ours, or maximized and already changed. A
                // settle that has come to rest in a state needing nothing is over.
                pending.removeValue(forKey: window.wid)
                continue
            }
            guard let waiting = pending[window.wid] else {
                pending[window.wid] = (window.maximized, now)
                continue
            }
            if waiting.state != window.maximized {
                // It turned back before the settle ended: the clock starts again, so a window the
                // user is dragging is never changed mid-drag.
                pending[window.wid] = (window.maximized, now)
                continue
            }
            let settle = window.maximized ? applySettle : restoreSettle
            if now - waiting.since < settle { continue }
            pending.removeValue(forKey: window.wid)
            if window.maximized {
                applied[window.wid] = window.pid
                decision.apply[window.pid, default: []].append(window.wid)
            } else {
                let owner = applied.removeValue(forKey: window.wid)!
                decision.restore[owner, default: []].append(window.wid)
            }
        }

        // A window off screen — minimized, on another Space, closed — keeps its record, because it may
        // still be showing our change. A settle in progress is dropped: on its return the window is
        // one we have just seen, not one that has been filling the area for minutes.
        for wid in pending.keys where !seen.contains(wid) {
            pending.removeValue(forKey: wid)
        }

        // Records are bounded by the windows on screen; past the cap the ones we cannot see are the
        // ones to give away, since a window that is not on screen is not one the user is looking at.
        if applied.count > maxRecords {
            for wid in applied.keys where !seen.contains(wid) {
                applied.removeValue(forKey: wid)
            }
        }
        return decision
    }

    /// Every window we have changed and not put back, grouped by the process it was recorded against:
    /// what to hand back when the loop stops. Windows that are off screen are included — the app is
    /// very likely still showing the change, and the app being gone is the engine's problem, not a
    /// reason to forget we changed it. `now` is the moment of stopping, kept in the signature the
    /// loop calls with; a restore-all is immediate and settles nothing.
    public func restoreAll(at now: TimeInterval) -> [pid_t: [UInt32]] {
        var restored: [pid_t: [UInt32]] = [:]
        for (wid, owner) in applied {
            restored[owner, default: []].append(wid)
        }
        for (owner, wids) in restored {
            restored[owner] = wids.sorted()  // a stable order, so a run can be compared with a run
        }
        applied.removeAll()
        pending.removeAll()
        return restored
    }
}
