import SwiftUI

struct ShiftPanel: View {
    @Environment(ShiftStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.hasToken {
                OnboardingSection(openSettings: openSettings)
            } else {
                HeaderSection()
                if let snapshot = store.snapshot {
                    TimeSection(snapshot: snapshot, now: store.now, autoBreakEnd: store.autoBreakEnd)
                } else {
                    Text("Lade Status…").foregroundStyle(.secondary)
                }
                if let totals = TodayTotals(summary: store.workSummary, snapshot: store.snapshot, now: store.now) {
                    Divider()
                    TodaySection(totals: totals)
                }
                Divider()
                ActionSection()
                MessageSection(openSettings: openSettings)
            }
            Divider()
            FooterSection(openSettings: openSettings)
        }
        .padding(16)
        .frame(width: 300)
        .background(WindowReader(window: $hostWindow))
        .onAppear { store.panelDidAppear() }
        .onDisappear { store.panelDidDisappear() }
        // `onAppear` is not guaranteed on every reopen of a MenuBarExtra window; key-window changes are the backup.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === hostWindow { store.panelDidAppear() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if (note.object as? NSWindow) === hostWindow { store.panelDidDisappear() }
        }
    }

    private func openSettings() {
        SettingsOpener.open(openWindow)
    }
}

/// Exposes the `NSWindow` hosting a view.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

// MARK: - Sections

private struct OnboardingSection: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timebutler").font(.headline)
            Text("Hinterlege dein persönliches API-Token, um loszulegen.")
                .foregroundStyle(.secondary)
            Button("Einstellungen öffnen", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Token in Timebutler erstellen") {
                NSWorkspace.shared.open(TimebutlerLinks.createToken)
            }
            .controlSize(.large)
        }
    }
}

private struct HeaderSection: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        let status = store.snapshot?.status ?? .unknown
        HStack {
            Text(status.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color(for: status).opacity(0.18), in: Capsule())
                .foregroundStyle(color(for: status))
            Spacer()
            if let name = store.profileName {
                Text("Angemeldet als \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func color(for status: ClockStatus) -> Color {
        switch status {
        case .running: .green
        case .paused: .orange
        case .waiting: .blue
        case .idle, .unknown: .secondary
        }
    }
}

private struct TimeSection: View {
    let snapshot: ShiftSnapshot
    let now: Date
    let autoBreakEnd: Date?

    var body: some View {
        if snapshot.isActive {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(DurationFormatting.hmmss(snapshot.netWork(at: now)))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("Arbeitszeit (netto)").font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    if let start = snapshot.shiftStart {
                        row("Beginn", DurationFormatting.clockTime(start))
                    }
                    row("Brutto (seit Beginn)", DurationFormatting.hmm(snapshot.gross(at: now)))
                    row("Pausen gesamt", DurationFormatting.hmm(snapshot.totalBreak(at: now)))
                    if snapshot.status == .paused {
                        let since = snapshot.breakStart.map { DurationFormatting.clockTime($0) + " " } ?? ""
                        row("In Pause seit", "\(since)(\(DurationFormatting.mss(snapshot.currentBreak(at: now))))")
                    }
                    if snapshot.status == .paused, let end = autoBreakEnd {
                        row("Endet automatisch", "\(DurationFormatting.clockTime(end)) (noch \(DurationFormatting.mss(max(0, end.timeIntervalSince(now)))))")
                    }
                    if let wait = snapshot.waitRemaining(at: now) {
                        row("Wartezeit", DurationFormatting.mss(wait))
                    }
                }
            }
        } else if snapshot.status == .idle {
            Text("Noch nicht eingestempelt.").foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct TodaySection: View {
    let totals: TodayTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heute").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                row("Gearbeitet", DurationFormatting.hmm(totals.workedSeconds))
                row("Soll", DurationFormatting.hmm(totals.targetSeconds))
                if totals.overtimeSeconds > 0 {
                    row("Überstunden", DurationFormatting.hmm(totals.overtimeSeconds))
                } else {
                    row("Rest", DurationFormatting.hmm(totals.remainingSeconds))
                }
                row("Pausen heute", DurationFormatting.hmm(totals.breakSeconds))
            }
            ProgressView(value: totals.progress)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct ActionSection: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        let status = store.snapshot?.status ?? .unknown
        let dto = store.snapshot?.dto
        VStack(spacing: 8) {
            if let info = store.pendingConfirmation {
                BreakRegulationConfirmation(info: info)
            } else if let pending = store.pendingAction {
                InlineConfirmation(action: pending)
            } else {
                switch status {
                case .idle:
                    primary("Einstempeln", terminalOnly: dto?.startOnlyOnTerminal == true) { await store.clockIn() }
                case .running:
                    primary("Pause starten", terminalOnly: dto?.pauseOnlyOnTerminal == true) { await store.startBreak() }
                    if store.autoBreakEnabled { autoBreakRow(terminalOnly: dto?.pauseOnlyOnTerminal == true) }
                    secondaryButtons(dto)
                case .paused:
                    primary("Pause beenden", terminalOnly: dto?.pauseOnlyOnTerminal == true) { await store.endBreak() }
                    if store.autoBreakEnd != nil {
                        Button("Automatisches Ende aufheben") { store.cancelAutoBreak() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    secondaryButtons(dto)
                case .waiting:
                    secondaryButtons(dto)
                case .unknown:
                    EmptyView()
                }
            }
            if store.isBusy { ProgressView().controlSize(.small) }
        }
        .disabled(store.isBusy)
    }

    private func primary(_ title: String, terminalOnly: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(terminalOnly)
            .help(terminalOnly ? "Nur am Terminal möglich" : "")
    }

    private func autoBreakRow(terminalOnly: Bool) -> some View {
        HStack(spacing: 6) {
            Text("Auto-Pause").font(.caption).foregroundStyle(.secondary)
            ForEach(ShiftStore.autoBreakMinutes, id: \.self) { minutes in
                Button { Task { await store.startBreak(autoEndAfter: minutes) } } label: {
                    Text("\(minutes) Min").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .disabled(terminalOnly)
        .help(terminalOnly ? "Nur am Terminal möglich" : "")
    }

    @ViewBuilder
    private func secondaryButtons(_ dto: TimeClockStatusDto?) -> some View {
        let stopTerminalOnly = dto?.stopOnlyOnTerminal == true
        Button { store.requestClockOut() } label: { Text("Ausstempeln").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(stopTerminalOnly)
            .help(stopTerminalOnly ? "Nur am Terminal möglich" : "")
        Button { store.requestCancel() } label: { Text("Abbrechen").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
    }
}

private struct InlineConfirmation: View {
    @Environment(ShiftStore.self) private var store
    let action: ShiftStore.PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch action {
            case .clockOut:
                Text("Schicht jetzt beenden und speichern?")
                confirmButton("Ausstempeln", prominent: true) { await store.clockOut() }
            case .cancel:
                let net = store.snapshot?.netWork(at: store.now) ?? 0
                Text("Schicht verwerfen? Die erfasste Zeit (\(DurationFormatting.hmm(net))) wird **nicht** gespeichert.")
                confirmButton("Verwerfen", prominent: false, destructive: true) { await store.cancelShift() }
            }
            Button { store.dismissConfirmation() } label: { Text("Zurück").frame(maxWidth: .infinity) }
                .controlSize(.large)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func confirmButton(
        _ title: String, prominent: Bool, destructive: Bool = false, action: @escaping () async -> Void
    ) -> some View {
        Button { Task { await action() } } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(destructive ? .red : .accentColor)
    }
}

private struct BreakRegulationConfirmation: View {
    @Environment(ShiftStore.self) private var store
    let info: BreakRegulationInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pausenregelung").font(.subheadline.weight(.semibold))
            if let text = info.detailText.map(Self.stripHTML), !text.isEmpty {
                Text(text).font(.callout)
            }
            if let work = info.resultingWorkMinutes, let pause = info.resultingBreakMinutes {
                Text("Ergebnis: \(DurationFormatting.minutesHmm(work)) Arbeit, \(DurationFormatting.minutesHmm(pause)) Pause")
                    .font(.callout.weight(.medium))
            }
            Button { Task { await store.confirmClockOut(apply: true) } } label: {
                Text("Korrektur übernehmen").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if info.obligatory != true {
                Button { Task { await store.confirmClockOut(apply: false) } } label: {
                    Text("Unverändert speichern").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            Button { store.dismissConfirmation() } label: { Text("Zurück").frame(maxWidth: .infinity) }
                .controlSize(.large)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Defensively removes HTML tags from the server's text.
    static func stripHTML(_ text: String) -> String {
        text.replacing(/<[^>]+>/, with: " ")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MessageSection: View {
    @Environment(ShiftStore.self) private var store
    let openSettings: () -> Void

    var body: some View {
        if let error = store.lastError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Erneut versuchen") { Task { await store.manualRefresh() } }
                    if error == .unauthorized || error == .noToken {
                        Button("Einstellungen öffnen", action: openSettings)
                    }
                    Button("Schließen") { store.dismissError() }
                }
                .controlSize(.small)
            }
        }
        if let message = store.transientMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FooterSection: View {
    @Environment(ShiftStore.self) private var store
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let last = store.lastRefresh {
                    Text("Aktualisiert \(DurationFormatting.clockTimeWithSeconds(last))")
                }
                Spacer()
                Button { Task { await store.manualRefresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Aktualisieren")
                .disabled(!store.hasToken)
            }
            HStack {
                Button("Timebutler öffnen") { NSWorkspace.shared.open(TimebutlerLinks.web) }
                Button("Einstellungen…", action: openSettings)
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.link)
    }
}
