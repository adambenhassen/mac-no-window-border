import AppKit
import Foundation
import NoBorderEngine
import NoBorderLogic

/// The app's engine: the scan loop, running in this process. This is the one object the menu talks
/// to, and the only place that decides when the loop runs.
///
/// The window changes themselves are made inside the apps that own them: see `ScanLoop` and
/// `NativeEngine`.
@MainActor
final class EngineManager: ObservableObject {
    @Published private(set) var status: EngineStatus = .off
    @Published private(set) var enabled: Bool

    private var loop: ScanLoop?
    private var log: FileHandle? = LogFile.open()

    /// The only way `status` is set. The loop reports the number of windows it has changed on every
    /// cycle — four a second — and a report that repeats the last one is not news: telling SwiftUI
    /// the menu changed makes it redraw the menu bar item, which is what this app's idle CPU is.
    private lazy var reported = StatusPublisher(status) { [weak self] next in
        self?.status = next
    }

    init() {
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        // A Dock quit, a Cmd-Q, a "Quit" from anywhere: the windows we changed go back before the
        // process goes, which is the whole reason the app is the one making the changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "enabled")
        if on { start() } else { stop() }
    }

    /// Quit: put the user's windows back first, then leave.
    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - the loop

    private func start() {
        guard loop == nil else { return }
        // The engine is built with a forwarder because the loop's log is the place its lines are
        // filtered, and an engine is constructed before the loop that owns it.
        let forward = EngineLogForward()
        let engine = NativeEngine(log: forward.say)
        let newLoop = ScanLoop(scan: { WindowScan.scan() },
                               tracker: WindowTracker(),
                               engine: engine,
                               log: { [weak self] line in
                                   DispatchQueue.main.async { MainActor.assumeIsolated { self?.write(line) } }
                               },
                               status: { [weak self] changed in
                                   DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed(changed) } }
                               })
        forward.next = newLoop.engineLog()
        loop = newLoop
        newLoop.start()
        reported.started()
        reported.set(.running(windows: 0))
    }

    /// Stopping is synchronous on purpose: the loop's `stop` is what puts every changed window back,
    /// and the app must not be gone before that has been asked for.
    private func stop() {
        guard let loop = loop else { return }
        self.loop = nil
        reported.stopped()
        loop.stop()
        reported.set(.off)
    }

    // MARK: - what the loop says

    private func changed(_ windows: Int) {
        reported.report(.running(windows: windows))
    }

    private func write(_ line: String) {
        guard let log else { return }
        if !LogFile.write(log, line) { self.log = nil }
    }
}

/// The engine's log path, before the loop exists to filter it.
private final class EngineLogForward {
    var next: ((String) -> Void)?
    func say(_ line: String) { next?(line) }
}
