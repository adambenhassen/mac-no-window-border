import AppKit
import Combine
import Foundation
import NoBorderCore
import NoBorderEngine
import NoBorderLogic

/// Which engine this run of the app uses, and the one object the menu talks to.
///
/// `legacy` runs the bundled `noborder.py` through `DaemonController`, unchanged: a child process,
/// LLDB, the `status:` pipe. `native` runs the scan loop in this process with `NativeEngine`. The
/// choice is made once, at startup, by `EngineChoice`, and both paths are kept because the phase's
/// rule is that the native engine does not become the default until it is measured stopping an app's
/// main loop by less than 5 ms.
///
/// What the user sees is the same either way: the status line, the On/Off, the Quit, and the same
/// log file. Everything below the choice is the engine's own code; this type only picks, forwards,
/// and stops.
@MainActor
final class EngineManager: ObservableObject {
    @Published private(set) var status: DaemonStatus = .off
    @Published private(set) var enabled: Bool

    let choice: EngineChoice

    private var legacy: DaemonController?
    private var native: ScanLoop?
    private var observed: AnyCancellable?
    private var log: FileHandle? = LogFile.open()

    init() {
        choice = EngineChoice.current()
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        if choice == .native {
            // A Dock quit, a Cmd-Q, a "Quit" from anywhere: the windows we changed go back before the
            // process goes, which is the whole reason the app is the one making the changes.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopNative() }
            }
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
        switch choice {
        case .legacy:
            // The controller stops the daemon, waits for it to restore, and terminates the app.
            legacyController().quit()
        case .native:
            stopNative()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - starting and stopping

    private func start() {
        switch choice {
        case .legacy:
            legacyController().setEnabled(enabled)
        case .native:
            startNative()
        }
    }

    private func stop() {
        switch choice {
        case .legacy:
            legacyController().setEnabled(false)
        case .native:
            stopNative()
        }
    }

    private func legacyController() -> DaemonController {
        if let existing = legacy { return existing }
        let controller = DaemonController()
        legacy = controller
        // The daemon's status, in the menu, in the same words as before: this app has always shown
        // what the child process said about itself.
        observed = controller.$status.sink { [weak self] status in
            MainActor.assumeIsolated { self?.status = status }
        }
        return controller
    }

    private func startNative() {
        guard native == nil else { return }
        // The engine is built with a forwarder because the loop's log is the place its lines are
        // filtered: an engine is constructed before the loop that owns it, and both end up talking to
        // the same sink.
        let forward = EngineLogForward()
        let engine = NativeEngine(log: forward.say)
        let loop = ScanLoop(scan: { WindowScan.scan() },
                            tracker: WindowTracker(),
                            engine: engine,
                            log: { [weak self] line in
                                DispatchQueue.main.async { MainActor.assumeIsolated { self?.write(line) } }
                            },
                            status: { [weak self] changed in
                                DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed(changed) } }
                            })
        forward.next = loop.engineLog()
        native = loop
        loop.start()
        status = .running(windows: 0)
    }

    /// Stopping is synchronous on purpose: the loop's `stop` is what puts every changed window back,
    /// and the app must not be gone before that has been asked for.
    private func stopNative() {
        guard let loop = native else { return }
        native = nil
        status = .stopping
        loop.stop()
        status = .off
    }

    // MARK: - what the loop says

    private func changed(_ windows: Int) {
        status = .running(windows: windows)
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
