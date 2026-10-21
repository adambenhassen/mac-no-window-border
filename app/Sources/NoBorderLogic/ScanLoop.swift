import Darwin
import Foundation
import NoBorderEngine

/// The loop that changes windows: scan, settle, ask the engine — every 250 ms, on one serial
/// queue, and immediately when the app is kicked by a focus change (`kick`).
///
/// This is the app's daemon: the scanner and the engine are in the same process, so there is no child
/// to supervise, no `status:` pipe to read, and no reason for the scan to be slower than the settle
/// it enforces. Everything it touches is injected — the scan, the clock, the engine, the log, the
/// status — because the interesting parts (what a cycle asks for, what a stop leaves behind, what is
/// said about a refusal) are all decisions, and decisions get tested.
///
/// One serial queue, with the timer's events on it, is what keeps two cycles out of the same app's
/// main thread at once: a call script runs in an app that is not running its own code, and a second
/// one asking the same app to do that is a second app stop. A slow engine therefore delays the next
/// cycle, which is the right way round: the scan cadence is a floor for noticing, not a deadline.
public final class ScanLoop {
    public typealias Scan = () -> [ScannedWindow]
    /// A monotonic-enough clock, in seconds. A scan's time is passed to the tracker, so a settle is
    /// a length of time and not a number of scans.
    public typealias Clock = () -> TimeInterval
    public typealias Log = (String) -> Void
    /// How many windows we have changed and not put back. The menu's line, and the only number in
    /// the app that knows what the user is being shown.
    public typealias Status = (_ windowsChanged: Int) -> Void

    /// The current "hide window buttons" option, read fresh every cycle: turning it off while a
    /// window stays maximized has to reach that window, and it is this closure that says so.
    public typealias ButtonsSetting = () -> Bool

    private let interval: TimeInterval
    private let now: Clock
    private let scan: Scan
    private let tracker: WindowTracker
    private let engine: ChangeEngine
    private let buttonsHidden: ButtonsSetting
    private let emit: Log
    private let status: Status

    private let queue = DispatchQueue(label: "com.noborder.scanloop")
    private var timer: DispatchSourceTimer?
    /// A loop is live until it is stopped: `stop()` is the end, and after it no cycle runs.
    private var stopped = false
    /// Refusals already said, keyed by what they are about. See `engineLog`.
    private var said: Set<String> = []
    /// When each app was last asked for its key windows, and the floor on that ask. See `cycle`.
    private var lastKeyRead: [pid_t: TimeInterval] = [:]
    private let keyReadInterval: TimeInterval

    /// A refusal that is a fact about a process: it will be refused for as long as that process
    /// lives, so the first one is the news.
    private static let perProcess = ["skipped (not AppKit)", "engine failed", "engine refused"]
    /// A refusal that is a fact about a moment: an app we have just changed stays un-parkable for
    /// seconds, and `not-parked` is a normal answer. It is news when the set of windows deferred
    /// changes, and not four times a second while it does not.
    private static let perBatch = ["skipped (not parked)"]

    public init(interval: TimeInterval = 0.25,
                now: @escaping Clock = { Date().timeIntervalSince1970 },
                scan: @escaping Scan,
                tracker: WindowTracker = WindowTracker(),
                engine: ChangeEngine,
                buttonsHidden: @escaping ButtonsSetting = { false },
                keyReadInterval: TimeInterval = 2.0,
                log: @escaping Log,
                status: @escaping Status = { _ in }) {
        self.interval = interval
        self.keyReadInterval = keyReadInterval
        self.now = now
        self.scan = scan
        self.tracker = tracker
        self.engine = engine
        self.buttonsHidden = buttonsHidden
        self.emit = log
        self.status = status
    }

    deinit { timer?.cancel() }

    public func start() {
        queue.sync {
            guard stopped else { return }
            stopped = false
            said.removeAll()  // a new run: the refusals are news again
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.cycle() }
        // (The timer's cycles obey the key-read floor; a focus kick's cycle does not — see `kick`.)
        queue.sync { timer = source }
        source.resume()
        queue.async { [weak self] in self?.cycle() }  // scan now; a window is not found on the next tick
    }

    /// Put every window we changed back, then release what the engine holds on the user's processes.
    ///
    /// Called from the main thread (the menu's Off and Quit, and the app's termination): it waits for
    /// a cycle in flight, because that cycle is in the same apps we are about to restore. Nothing
    /// after the first call does anything — the engine is shut down exactly once.
    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            for (pid, wids) in tracker.restoreAll(at: now()).sorted(by: { $0.key < $1.key }) {
                engine.restore(pid: pid, windows: wids)
            }
            engine.shutdown()
            status(0)
        }
        let source = queue.sync { () -> DispatchSourceTimer? in
            let existing = timer
            timer = nil
            return existing
        }
        source?.cancel()
    }

    /// One cycle, on the loop's queue. The seam the tests drive: they set the clock, ask for a
    /// cycle, and look at what the engine was asked to do.
    func step() {
        queue.sync { if !stopped { cycle() } }
    }

    /// Run a cycle now, without waiting for the timer.
    ///
    /// The app is listening to focus changes as they happen (`NSWorkspace`'s activation
    /// notification, in-process, free); a window going in and out of focus is exactly the moment
    /// an app repaints its decorations over our change, and a cycle asked for at that moment
    /// puts the change back in single-digit milliseconds instead of up to a scan interval.
    /// Cycles are serial and cheap, so a burst of notifications is a burst of scans, not a
    /// stampede.
    ///
    /// A kick's cycle re-asserts every applied window without a key read (`cycle(isUserKick:)`
    /// → `transitionsAreUser`): the activation says a focus change just happened, the app is busy
    /// repainting at that moment so a read would only time out, and the re-apply must not wait on
    /// it. The read belongs to the timer path, which catches a repaint with no user behind it.
    public func kick() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }   // a stop is the end: no cycles after it
            self.cycle(isUserKick: true)
        }
    }

    /// The closure an engine is constructed with.
    ///
    /// The engine reports every refusal of every scan — it does not know what it said last time, and
    /// it should not have to. A process with no application object, or one with no task port, is
    /// refused four times a second forever; the first of those is the news. `not-parked` is not a
    /// broken app, it is an app that is busy, so it is said once per set of windows deferred, and
    /// again when that set changes. A change that happened is always said: it is what the user asked
    /// this app to do.
    public func engineLog() -> Log {
        { [weak self] line in self?.say(line) }
    }

    private func say(_ line: String) {
        if let key = refusalKey(for: line) {
            guard !said.contains(key) else { return }
            said.insert(key)
        }
        emit(line)
    }

    private func cycle(isUserKick: Bool = false) {
        let at = now()
        let hidden = buttonsHidden()
        let windows = scan()
        var keyStates: [UInt32: Bool] = [:]
        // A key read is an entry into the app: it needs the app's main thread parked, and at
        // focus-in the app is busy repainting, so the read times out (~200 ms, measured
        // 2026-10-21) and queues behind the app's own work. A focus kick does not read — it
        // re-asserts applied windows unconditionally (WindowTracker.update, transitionsAreUser).
        // The read runs only on the timer path, where it detects an app repainting our change on
        // its own (a repaint war — AppKit's rim, iTerm's outline, both measured 2026-10-20) and
        // feeds the undo budget; it is floored per app because asking every applied window every
        // cycle cost a measured 5% of a core.
        if !isUserKick {
            for (pid, wids) in tracker.appliedWindows(in: windows).sorted(by: { $0.key < $1.key }) {
                if let last = lastKeyRead[pid], at - last < keyReadInterval { continue }
                lastKeyRead[pid] = at
                keyStates.merge(engine.keyWindows(pid: pid, windows: wids)) { _, new in new }
            }
        }
        // A kick re-asserts applied windows: `transitionsAreUser` makes the tracker serve them
        // with no key read and without striking — the activation is the user's own switch.
        let decision = tracker.update(windows: windows, at: at, buttonsHidden: hidden,
                                      keyStates: keyStates, transitionsAreUser: isUserKick)
        // Restores before applies: a window the user un-maximized is theirs to have back, and a
        // process that goes busy in the middle then only has the apply deferred.
        for (pid, wids) in decision.restore.sorted(by: { $0.key < $1.key }) {
            let deferred = engine.restore(pid: pid, windows: wids)
            if !deferred.isEmpty { tracker.undoRestore(deferred, of: pid, buttonsHidden: hidden) }
        }
        for (pid, wids) in decision.apply.sorted(by: { $0.key < $1.key }) {
            let deferred = engine.apply(pid: pid, windows: wids, buttonsHidden: hidden)
            if !deferred.isEmpty { tracker.undoApply(deferred) }
        }
        // A window that just ran out of its undo budget is named once: it is a line the user
        // should see, and a window crosses that line exactly once per stay.
        for (pid, wids) in decision.gaveUp.sorted(by: { $0.key < $1.key }) {
            let batch = wids.map(String.init).joined(separator: " ")
            emit("left alone (kept undoing) \(pid) \(batch)")
        }
        status(tracker.appliedCount)
    }

    /// The key of a refusal: what it is about. `nil` for a line that is not a refusal.
    private func refusalKey(for line: String) -> String? {
        for prefix in Self.perBatch where line.hasPrefix(prefix) {
            // "<verb> <pid> <wid> <wid>": the process and the set of windows it deferred.
            let parts = line.dropFirst(prefix.count).split(separator: " ").map(String.init)
            guard let pid = parts.first else { continue }
            return "\(prefix) \(pid) \(parts.dropFirst().sorted().joined(separator: " "))"
        }
        for prefix in Self.perProcess where line.hasPrefix(prefix) {
            // "<verb> <pid> <wid>…: <reason>": the process and the reason. A new reason is news.
            let rest = String(line.dropFirst(prefix.count))
            let head = rest.components(separatedBy: ":").first ?? rest
            let reason = rest.components(separatedBy: ":").dropFirst().joined(separator: ":")
            let pid = head.split(separator: " ").compactMap { Int($0) }.first.map(String.init) ?? "?"
            return "\(prefix) \(pid) \(reason)"
        }
        return nil
    }
}
