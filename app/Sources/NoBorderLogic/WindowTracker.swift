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
    /// Windows whose undo budget just ran out: the tracker stops asking for them, and the caller
    /// says so — once, because a window crosses that line exactly once per stay.
    public var gaveUp: [pid_t: [UInt32]]

    public init(apply: [pid_t: [UInt32]] = [:], restore: [pid_t: [UInt32]] = [:], gaveUp: [pid_t: [UInt32]] = [:]) {
        self.apply = apply
        self.restore = restore
        self.gaveUp = gaveUp
    }
}

/// Which windows are ours to change, and when to change them.
///
/// The window decisions, with the three things this path has no use for left out: the no-shadow tag
/// and its untag (the changes are made inside the app, and are not a WindowServer tag), a backoff for
/// a tag a window keeps putting back, and a launch grace for young processes. What is kept is the part
/// that is about user-visible behaviour:
///
/// - a window has to fill the usable area for `applySettle` before it is changed, and stop filling it
///   for `restoreSettle` before it is put back, so a drag is never fought over;
/// - only a window in `applied` is ever restored — we undo our own changes and nothing else;
/// - a window that leaves the screen keeps its record: the app may have undone our change while we
///   could not see it, and when the window comes back it is still ours;
/// - a window whose key state changed since the last read is applied again, on the spot: apps
///   repaint their decorations around focus transitions — AppKit's key rim on focus-in, iTerm's
///   outline on focus-out (both measured 2026-10-20) — and the repaint puts our change under the
///   app's drawing. The first read of a window is the baseline, not a transition; a steady key
///   state starts the budget over. Past `undoLimit` transitions in a row the window is left
///   alone — focus changes are the user's, and a window flapped four times in a row is not one
///   to fight. Un-maximizing hands the record back to the normal rules.
///
/// `update` is called once per scan with the whole screen, at a time the caller supplies, so a settle
/// is a thing the tests can drive. Nothing here talks to a process; the caller hands each decision to
/// an engine, and a window whose app is busy simply stays in the state it is in until the next scan.
public final class WindowTracker {
    private let applySettle: TimeInterval
    private let restoreSettle: TimeInterval
    private let maxRecords: Int
    /// How many key-state transitions in a row one window may cost, before the tracker gives up
    /// on it until the state goes steady again.
    private let undoLimit: Int

    /// One window's record of a change we owe the user.
    private struct AppliedRecord {
        let pid: pid_t
        /// The buttons state we asked the engine for. The option can change while a window stays
        /// maximized, and this is what says the window needs asking again.
        var buttonsHidden: Bool
        /// The key state of the window's last read, `nil` before the first: the transition from
        /// this to the next read is the event that puts the app's drawing back.
        var lastKey: Bool?
        /// Transitions found in a row, since the key state was last seen steady.
        var strikes = 0
        /// The budget ran out: stop asking. Cleared when the window is seen changed again, and by
        /// the restore when it un-maximizes, which drops the record entirely.
        var surrendered = false
    }

    /// wid -> the change we made to it. The record of a change we owe the user: only a window in
    /// here is ever restored, and it is restored to the process recorded here, not to whoever owns
    /// that window number now.
    private var applied: [UInt32: AppliedRecord] = [:]

    /// wid -> (the state it has to keep for the settle to end, the moment it started keeping it).
    private var pending: [UInt32: (state: Bool, since: TimeInterval)] = [:]

    public init(applySettle: TimeInterval = 0.5, restoreSettle: TimeInterval = 0.5, maxRecords: Int = 4096,
                undoLimit: Int = 3) {
        self.applySettle = applySettle
        self.restoreSettle = restoreSettle
        self.maxRecords = maxRecords
        self.undoLimit = undoLimit
    }

    /// The windows of one scan that we have changed and not put back, grouped by the process that
    /// owns them: what a state read is asked of. A window off screen is not in it — a read asks
    /// about what the user can see right now, and a read is one stop in a live app.
    public func appliedWindows(in windows: [ScannedWindow]) -> [pid_t: [UInt32]] {
        var grouped: [pid_t: [UInt32]] = [:]
        for window in windows where applied[window.wid] != nil {
            grouped[applied[window.wid]!.pid, default: []].append(window.wid)
        }
        for (pid, wids) in grouped { grouped[pid] = wids.sorted() }
        return grouped
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
    public func undoRestore(_ windows: [UInt32], of pid: pid_t, buttonsHidden: Bool = false) {
        for wid in windows {
            applied[wid] = AppliedRecord(pid: pid, buttonsHidden: buttonsHidden)
            pending.removeValue(forKey: wid)
        }
    }

    /// `buttonsHidden` is the app's current option. An applied window that disagrees with it is applied
    /// again on the spot: the window's state is not what changed, the user's option is, and the settle
    /// guards a drag — not a resync of a window that has been at rest and ours for as long as we have
    /// the record.
    ///
    /// `keyStates` is what the engine's key state read answered this scan, per window: an entry
    /// whose value changed from the window's last read is a focus transition, and an applied window
    /// at a transition is applied again, per the undo policy above. No entry is "the read did not
    /// run": nothing is concluded from it.
    ///
    /// `transitionsAreUser` says this scan ran *because* an activation notification arrived — the
    /// user just switched apps. Every applied window is then re-asserted unconditionally, with no
    /// key read: at focus-in the app is busy repainting and the read times out (~200 ms, measured
    /// 2026-10-21), so gating the re-apply on it leaves the repaint standing — the live iTerm bug.
    /// A user switch never strikes and brings a surrendered window back into service: normal app
    /// switching flips the key state of every applied window, and the three-flap budget burned
    /// itself out on real switching (measured 2026-10-20: 69 surrenders in a live session, the
    /// user's iTerm window left with its rim). Only transitions a timer read finds on its own —
    /// a window repainting without the user asking — feed the budget.
    public func update(windows: [ScannedWindow], at now: TimeInterval, buttonsHidden: Bool = false,
                       keyStates: [UInt32: Bool] = [:], transitionsAreUser: Bool = false)
                       -> TrackerDecision {
        var decision = TrackerDecision()
        var seen: Set<UInt32> = []
        for window in windows {
            seen.insert(window.wid)
            if window.maximized, var record = applied[window.wid] {
                // A user focus kick re-asserts the window unconditionally. The user just switched
                // apps; the app repaints its decorations around that, and the repaint can land
                // after the notification's answer (measured live 2026-10-21: switch away from
                // iTerm and back, the outline standing). The native key read is not consulted here
                // — at focus-in the app is busy repainting, so the read times out (~200 ms,
                // answering nothing), and gating the re-apply on it leaves the repaint standing.
                // The agent op is a queued message that drains without a park, so a fresh gen
                // re-runs the idempotent setters. The read runs only on the timer path below,
                // where it feeds the repaint-war budget; a user switch is not that war, so it
                // strikes nothing and brings a surrendered window back into service.
                if transitionsAreUser {
                    record.lastKey = keyStates[window.wid]   // empty on a kick: re-baseline the timer path
                    record.strikes = 0
                    record.surrendered = false
                    record.buttonsHidden = buttonsHidden
                    applied[window.wid] = record
                    pending.removeValue(forKey: window.wid)
                    decision.apply[window.pid, default: []].append(window.wid)
                    continue
                }
                // The timer path. The key state and the option are the two things that can ask for
                // more. A key state that moved since the last read — with no user switch — is an
                // app repainting our change on its own, the event that puts its drawing back
                // (measured 2026-10-20, both directions): ask for the change back on the spot, and
                // feed the undo budget; past it the window is left alone until the state is steady.
                if let key = keyStates[window.wid] {
                    if record.lastKey == key {
                        // Steady since the last read: the transition, if there was one, is over.
                        // A window at rest is one to serve, not to surrender.
                        record.strikes = 0
                        record.surrendered = false
                        applied[window.wid] = record
                    } else if record.lastKey == nil {
                        // The first read of this window: the baseline, not a transition.
                        record.lastKey = key
                        applied[window.wid] = record
                    } else {
                        record.lastKey = key
                        if record.surrendered {
                            applied[window.wid] = record
                            continue
                        }
                        record.strikes += 1
                        applied[window.wid] = record
                        if record.strikes > undoLimit {
                            record.surrendered = true
                            applied[window.wid] = record
                            decision.gaveUp[window.pid, default: []].append(window.wid)
                        } else {
                            pending.removeValue(forKey: window.wid)
                            decision.apply[window.pid, default: []].append(window.wid)
                        }
                        continue
                    }
                }
                // Steady, baseline, or a read that did not run: the option is the only thing left.
                guard record.buttonsHidden != buttonsHidden else {
                    pending.removeValue(forKey: window.wid)
                    continue
                }
                record.buttonsHidden = buttonsHidden
                applied[window.wid] = record
                decision.apply[window.pid, default: []].append(window.wid)
                continue
            }
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
                applied[window.wid] = AppliedRecord(pid: window.pid, buttonsHidden: buttonsHidden)
                decision.apply[window.pid, default: []].append(window.wid)
            } else {
                let owner = applied.removeValue(forKey: window.wid)!.pid
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
        for (wid, record) in applied {
            restored[record.pid, default: []].append(wid)
        }
        for (owner, wids) in restored {
            restored[owner] = wids.sorted()  // a stable order, so a run can be compared with a run
        }
        applied.removeAll()
        pending.removeAll()
        return restored
    }
}
