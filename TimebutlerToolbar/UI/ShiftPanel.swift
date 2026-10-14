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
                Divider()
                ActionSection()
                MessageSection(openSettings: openSettings)
                if let totals = TodayTotals(summary: store.workSummary, snapshot: store.snapshot, now: store.now) {
                    Divider()
                    TodaySection(
                        totals: totals,
                        timeline: DayTimeline(
                            entries: store.timeEntries, snapshot: store.snapshot,
                            summary: store.workSummary, now: store.now
                        )
                    )
                }
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
            let paused = snapshot.status == .paused
            // Each counter carries its own details; the running one is large, the other stays small.
            VStack(alignment: .leading, spacing: 8) {
                counter(
                    "clock.fill", DurationFormatting.hmmss(snapshot.netWork(at: now)),
                    active: !paused, label: "Arbeitszeit"
                ) {
                    if let start = snapshot.shiftStart {
                        detail(.label("Eingestempelt seit "), .value(DurationFormatting.clockTime(start)))
                    }
                    if let wait = snapshot.waitRemaining(at: now) {
                        detail(.label("Wartezeit "), .value(DurationFormatting.mss(wait)))
                    }
                }
                counter(
                    "cup.and.heat.waves.fill", DurationFormatting.hmmss(snapshot.totalBreak(at: now)),
                    active: paused, label: "Pause"
                ) {
                    if paused {
                        if let since = snapshot.breakStart {
                            detail(
                                .label("In Pause seit "), .value(DurationFormatting.clockTime(since)),
                                .label(" ("), .value(DurationFormatting.mss(snapshot.currentBreak(at: now))), .label(")")
                            )
                        }
                        if let end = autoBreakEnd {
                            detail(
                                .label("Endet automatisch "), .value(DurationFormatting.clockTime(end)),
                                .label(" (noch "), .value(DurationFormatting.mss(max(0, end.timeIntervalSince(now)))), .label(")")
                            )
                        }
                    }
                }
            }
        } else if snapshot.status == .idle {
            Text("Noch nicht eingestempelt.").foregroundStyle(.secondary)
        }
    }

    private static let iconWidth: CGFloat = 30
    private static let iconSpacing: CGFloat = 8

    private func counter(
        _ symbol: String, _ value: String, active: Bool, label: String,
        @ViewBuilder details: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Self.iconSpacing) {
                Image(systemName: symbol)
                    .font(.system(size: active ? 24 : 14, weight: .semibold))
                    .frame(width: Self.iconWidth, alignment: .center)
                Text(value)
                    .font(.system(size: active ? 38 : 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(active ? .primary : .secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) \(value)")
            // Details align with the value, not the icon.
            VStack(alignment: .leading, spacing: 1) { details() }
                .padding(.leading, Self.iconWidth + Self.iconSpacing)
        }
    }

    private func detail(_ parts: StyledPart...) -> some View {
        styledText(parts).font(.callout)
    }
}

/// A piece of a mixed label/value line: labels are secondary, values primary for readability.
private enum StyledPart {
    case label(String)
    case value(String)
}

private func styledText(_ parts: [StyledPart]) -> Text {
    parts.reduce(Text("")) { text, part in
        switch part {
        case .label(let string): text + Text(string).foregroundStyle(.secondary)
        case .value(let string): text + Text(string).foregroundStyle(.primary).monospacedDigit()
        }
    }
}

private struct TodaySection: View {
    let totals: TodayTotals
    let timeline: DayTimeline?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heute").font(.subheadline.weight(.semibold))
            VStack(spacing: 4) {
                row("Gearbeitet", workedParts)
                row("Pausen heute", [.value(DurationFormatting.hmm(totals.breakSeconds))])
            }
            .font(.callout)
            if let timeline { DayTimelineBar(timeline: timeline) }
        }
    }

    /// Label on the left edge, value on the right edge.
    private func row(_ label: String, _ value: [StyledPart]) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            styledText(value)
        }
    }

    /// "5:22 von 7:00 (1:47 Rest)", or overtime instead of the rest.
    private var workedParts: [StyledPart] {
        let over = totals.overtimeSeconds > 0
        return [
            .value(DurationFormatting.hmm(totals.workedSeconds)),
            .label(" von "),
            .value(DurationFormatting.hmm(totals.targetSeconds)),
            .label(" ("),
            .value(DurationFormatting.hmm(over ? totals.overtimeSeconds : totals.remainingSeconds)),
            .label(over ? " Überstunden)" : " Rest)"),
        ]
    }
}

/// Today as a bar: work, breaks and untracked gaps, from the first clock-in to the planned end
/// (or beyond it, with a marker at the planned end).
private struct DayTimelineBar: View {
    let timeline: DayTimeline

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    ForEach(Array(timeline.segments.enumerated()), id: \.offset) { _, segment in
                        let x = timeline.fraction(segment.start) * width
                        Rectangle()
                            .fill(Self.color(segment.kind))
                            .frame(width: max(1, timeline.fraction(segment.end) * width - x))
                            .offset(x: x)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .leading) {
                    if timeline.isOverrun {
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 2, height: 14)
                            .offset(x: timeline.fraction(timeline.plannedEnd) * width - 1)
                            .help("Soll inkl. Pause erreicht um \(DurationFormatting.clockTime(timeline.plannedEnd))")
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text(DurationFormatting.clockTime(timeline.start))
                Spacer()
                legend
                Spacer()
                Text(DurationFormatting.clockTime(timeline.end))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Tagesverlauf von \(DurationFormatting.clockTime(timeline.start)) bis \(DurationFormatting.clockTime(timeline.end))"
        )
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach([DayTimeline.Kind.work, .pause, .untracked], id: \.self) { kind in
                HStack(spacing: 3) {
                    Circle().fill(Self.color(kind)).frame(width: 6, height: 6)
                    Text(Self.title(kind))
                }
            }
        }
    }

    private static func color(_ kind: DayTimeline.Kind) -> Color {
        switch kind {
        case .work: .green
        case .pause: .orange
        case .untracked: .gray.opacity(0.45)
        }
    }

    private static func title(_ kind: DayTimeline.Kind) -> String {
        switch kind {
        case .work: "Arbeit"
        case .pause: "Pause"
        case .untracked: "Ohne Erfassung"
        }
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
