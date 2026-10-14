import SwiftUI

@main
struct TimebutlerToolbarApp: App {
    @State private var store = AppEnvironment.makeStore()
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some Scene {
        MenuBarExtra {
            ShiftPanel()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Window("Einstellungen", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(launchAtLogin)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
