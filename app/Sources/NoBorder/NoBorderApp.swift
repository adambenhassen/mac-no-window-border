import AppKit
import Darwin
import ServiceManagement
import SwiftUI

/// `kill -TERM` on a plain-binary app is the DEFAULT action: the process exits at once, and
/// `willTerminate` — the observer that stops the loop, restores the windows, and removes the
/// agents — never runs. Measured 2026-10-21: SIGTERM, process gone in <2 s, applied windows
/// left applied and agents left resident. The tests and any `kill` quit this way, so SIGTERM
/// is routed to the app's real quit (the Dock's quit and Cmd-Q already arrive through
/// `willTerminate`). The handler runs on a thread of the kernel's choosing: it bails to the
/// main queue, where `terminate` starts the normal termination, and the re-signal restores
/// the default in case termination itself stalls.
private func requestTerminateOnSIGTERM(_: Int32) {
    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    signal(SIGTERM, SIG_DFL)
}

@main
struct NoBorderApp: App {
    init() {
        signal(SIGTERM, requestTerminateOnSIGTERM)
    }

    @StateObject private var engines = EngineManager()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some Scene {
        MenuBarExtra("NoBorder", systemImage: "rectangle.dashed") {
            Text(engines.status.menuText)
            Divider()
            Toggle("Enabled", isOn: Binding(get: { engines.enabled }, set: { engines.setEnabled($0) }))
            Toggle("Hide window buttons", isOn: Binding(get: { engines.hideButtons }, set: { engines.setHideButtons($0) }))
            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            if let loginError {
                Text(loginError)
            }
            Divider()
            Button("Quit NoBorder") { engines.quit() }
                .keyboardShortcut("q")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
