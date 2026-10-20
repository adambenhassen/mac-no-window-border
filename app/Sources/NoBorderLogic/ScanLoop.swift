import Darwin
import Foundation
import NoBorderEngine

/// The loop that changes windows: scan, settle, ask the engine — every 250 ms, on one serial queue.
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

    /// A refusal that is a fact about a process: it will be refused for as long as that process
    /// lives, so the first one is the news.
    private static let perProcess = ["skipped (not AppKit)", "engine failed"]
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
                log: @escaping Log,
                status: @escaping Status = { _ in }) {
        self.interval = interval
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

    private func cycle() {
        let at = now()
        let hidden = buttonsHidden()
        let decision = tracker.update(windows: scan(), at: at, buttonsHidden: hidden)
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
