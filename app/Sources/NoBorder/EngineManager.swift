import AppKit
import Foundation
import NoBorderEngine
import NoBorderLogic
import NoBorderNative

/// SIGUSR1 = Off, SIGUSR2 = On, for the tests: the C handlers are file-scope (a C function
/// pointer cannot name a MainActor member) and call the installed instance hook. Off persists
/// to UserDefaults like the menu toggle does, so a test that stops the loop must re-enable
/// before the next launch.
private var toggleHandler: ((_ on: Bool) -> Void)?
private func onSIGUSR1(_: Int32) { toggleHandler?(false) }
private func onSIGUSR2(_: Int32) { toggleHandler?(true) }

/// The app's engine: the scan loop, running in this process. This is the one object the menu talks
/// to, and the only place that decides when the loop runs.
///
/// The window changes themselves are made inside the apps that own them: see `ScanLoop` and
/// `AgentEngine`.
/// The "hide window buttons" option, readable from the scan loop's queue. The menu writes it; the
/// loop's cycle reads it. A lock makes that handoff a plain fact, not a race to reason about.
final class ButtonSetting {
    private let lock = NSLock()
    private var hidden = false

    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return hidden }
        set { lock.lock(); hidden = newValue; lock.unlock() }
    }

    init(on: Bool) { hidden = on }
}

@MainActor
final class EngineManager: ObservableObject {
    @Published private(set) var status: EngineStatus = .off
    @Published private(set) var enabled: Bool
    @Published private(set) var hideButtons: Bool

    /// Shared with the scan loop, which reads it on its own queue every cycle.
    private let buttonSetting: ButtonSetting
    private var loop: ScanLoop?
    /// The focus-change listener, alive while the loop is.
    private var activation: NSObjectProtocol?
    private var log: FileHandle? = LogFile.open()

    /// The only way `status` is set. The loop reports the number of windows it has changed on every
    /// cycle — four a second — and a report that repeats the last one is not news: telling SwiftUI
    /// the menu changed makes it redraw the menu bar item, which is what this app's idle CPU is.
    private lazy var reported = StatusPublisher(status) { [weak self] next in
        self?.status = next
    }

    // Publication state (user decision 2026-10-21): the app runs on the resident agent. The
    // changes are messages to a CFMachPort source in the target's own run loop — no thread
    // entry per change; the dispatched entry (the Phase-0 hardened shape, poison.sh green)
    // runs only for agent install/removal and the 2 s-floored key reads. Quit removes every
    // installed agent, and restores every window it changed first.

    /// Said once per scan session, in the app's log, before the loop asks for anything: the mode,
    /// and the recovery path for windows an older, injecting build left changed (verdict 4,
    /// 2026-10-20: the line must arrive even when no window qualifies, and must name the way back).
    static let modeLine = "resident agent: changes are messages, no per-change thread entry; "
        + "quit removes the agents; an older build's leftovers: noborder-probe restore"

    init() {
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        let buttons = UserDefaults.standard.bool(forKey: "hideButtons")
        hideButtons = buttons
        buttonSetting = ButtonSetting(on: buttons)
        // A Dock quit, a Cmd-Q, a "Quit" from anywhere: the loop stops before the process goes,
        // and that stop puts every window the agent changed back and removes the agents.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if enabled { start() }
        // SIGUSR1 = the menu's Off, SIGUSR2 = the menu's On, for the tests (the hostapp apps
        // take signals the same way): stop() restores and releases, and the app stays alive so
        // the log lines land.
        toggleHandler = { [weak self] on in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setEnabled(on) } }
        }
        signal(SIGUSR1, onSIGUSR1)
        signal(SIGUSR2, onSIGUSR2)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "enabled")
        if on { start() } else { stop() }
    }

    /// The buttons option takes effect on the next scan (≤250 ms): the loop reads it fresh every
    /// cycle, and an applied window that disagrees with it is applied again with the new value.
    func setHideButtons(_ on: Bool) {
        hideButtons = on
        buttonSetting.isOn = on
        UserDefaults.standard.set(on, forKey: "hideButtons")
    }

    /// Quit: stop the loop (which restores the changed windows and removes the agents), then leave.
    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - the loop

    private func start() {
        guard loop == nil else { return }
        // The resident-agent engine: changes are messages to the agent;
        // key reads ride the shipped floored path. The loop's log closure is the one path
        // lines take to the file, and the engine's refusals speak through it too.
        let engineLog: (String) -> Void = { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.write(line) } }
        }
        let engine = AgentEngine(log: engineLog)
        let newLoop = ScanLoop(scan: { WindowScan.scan() },
                               tracker: WindowTracker(),
                               engine: engine,
                               buttonsHidden: { [buttonSetting] in buttonSetting.isOn },
                               log: engineLog,
                               status: { [weak self] changed in
                                   DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed(changed) } }
                               })
        write(Self.modeLine)
        loop = newLoop
        newLoop.start()
        // A focus change is the moment an app repaints its decorations over our change, and
        // NSWorkspace says when one happens — in-process, no polling. The loop's cycle, kicked at
        // that moment, puts the change back in milliseconds; the 250 ms scan stays the floor for
        // everything else.
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loop?.kick() }
        }
        reported.started()
        reported.set(.running(windows: 0))
    }

    /// Stopping is synchronous on purpose: the loop's `stop` is what puts every changed window back
    /// and releases the engine's holds (it removes the agents), and the app must not be gone before
    /// that has been asked for.
    private func stop() {
        guard let loop = loop else { return }
        self.loop = nil
        if let activation {
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
            self.activation = nil
        }
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
