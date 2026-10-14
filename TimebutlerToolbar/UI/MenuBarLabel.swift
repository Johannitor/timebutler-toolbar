import SwiftUI

struct MenuBarLabel: View {
    @Environment(ShiftStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.menuBarSymbol)
            if !store.menuBarText.isEmpty {
                Text(store.menuBarText).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.menuBarAccessibility)
        .task {
            // The label is created at launch, so this is the app's entry point.
            guard !AppEnvironment.isRunningTests else { return }
            store.start()
            if !store.hasToken { SettingsOpener.open(openWindow) }
        }
    }
}

enum SettingsOpener {
    @MainActor
    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: "settings")
        NSApp.activate()
    }
}
