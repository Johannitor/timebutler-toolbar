import SwiftUI

struct SettingsView: View {
    @Environment(ShiftStore.self) private var store
    @Environment(LaunchAtLogin.self) private var launchAtLogin

    @State private var tokenInput = ""
    @State private var isChecking = false
    @State private var feedback: Feedback?

    private struct Feedback {
        let text: String
        let isError: Bool
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Timebutler-Zugang") {
                if let masked = store.maskedToken {
                    LabeledContent("Status") {
                        HStack {
                            Text("Token gespeichert (\(masked))")
                            Button("Token entfernen", role: .destructive) {
                                store.removeToken()
                                feedback = nil
                            }
                        }
                    }
                    if let name = store.profileName {
                        LabeledContent("Angemeldet als", value: name)
                    }
                }
                SecureField("API-Token", text: $tokenInput, prompt: Text("tb_…"))
                    .onSubmit(check)
                HStack {
                    Button("Prüfen & speichern", action: check)
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
                    if isChecking { ProgressView().controlSize(.small) }
                }
                if let feedback {
                    Text(feedback.text)
                        .foregroundStyle(feedback.isError ? Color.red : Color.green)
                }
                Link("Persönliches Token in Timebutler erstellen…", destination: TimebutlerLinks.createToken)
                Text("Das Token wird sicher im macOS-Schlüsselbund gespeichert.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Allgemein") {
                Toggle("Bei Anmeldung starten", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("Bitte bestätige den Autostart in den Systemeinstellungen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Anmeldeobjekte öffnen") { launchAtLogin.openSystemSettings() }
                    }
                }

                Toggle("Pausenerinnerung (ArbZG)", isOn: $store.breakReminderEnabled)
                Text("Erinnert dich 15 Minuten bevor du 6 h bzw. 9 h Arbeitszeit erreichst, falls bis dahin noch nicht genug Pause (30 bzw. 45 Min.) erfasst ist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if store.notificationsDenied {
                    Text("Mitteilungen sind für diese App deaktiviert. Aktiviere sie in den Systemeinstellungen, damit Erinnerungen erscheinen.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Info") {
                LabeledContent("Version", value: Self.versionString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin.refresh() }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        feedback = nil
        let candidate = tokenInput
        Task {
            let result = await store.connect(token: candidate)
            isChecking = false
            switch result {
            case .connected(let name, let enabled):
                tokenInput = ""
                feedback = Feedback(
                    text: enabled
                        ? "✓ Verbunden als \(name)"
                        : "✓ Verbunden als \(name). Zeiterfassung ist für dein Konto nicht aktiviert.",
                    isError: !enabled
                )
            case .invalid:
                feedback = Feedback(text: "Token ungültig.", isError: true)
            case .failed(let error):
                feedback = Feedback(text: error.message, isError: true)
            }
        }
    }
}

enum TimebutlerLinks {
    static let web = URL(string: "https://app.timebutler.com")!
    static let createToken = URL(string: "https://app.timebutler.com/do?ha=personaltoken&ac=1")!
}
