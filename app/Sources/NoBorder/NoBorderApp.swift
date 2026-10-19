import NoBorderCore
import ServiceManagement
import SwiftUI

@main
struct NoBorderApp: App {
    @StateObject private var engines = EngineManager()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some Scene {
        MenuBarExtra("NoBorder", systemImage: "rectangle.dashed") {
            Text(engines.status.menuText)
            // Which engine this run is: the switch is a launch argument and a defaults key, so the
            // menu is the only place a person can see which one they are looking at.
            Text("Engine: \(engines.choice.rawValue)")
            Divider()
            Toggle("Enabled", isOn: Binding(get: { engines.enabled }, set: { engines.setEnabled($0) }))
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
