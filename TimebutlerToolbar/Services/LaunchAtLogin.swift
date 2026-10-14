import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?

    init() {
        status = SMAppService.mainApp.status
    }

    /// The toggle is on when registered, including the state where the user still has to approve.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Autostart konnte nicht geändert werden: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
