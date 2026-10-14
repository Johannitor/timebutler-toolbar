import AppKit
import Foundation
import Observation

extension ClockStatus {
    var displayName: String {
        switch self {
        case .idle: "Nicht eingestempelt"
        case .running: "Arbeitet"
        case .paused: "In Pause"
        case .waiting: "Wartet"
        case .unknown: "Unbekannt"
        }
    }
}

/// Central app state: polling, ticking, actions. Views only read from it and call its methods.
@MainActor
@Observable
final class ShiftStore {
    enum PendingAction: Equatable { case clockOut, cancel }

    enum ConnectResult: Equatable {
        case connected(name: String, timeTrackingEnabled: Bool)
        case invalid
        case failed(APIError)
    }

    // MARK: Observable state

    private(set) var snapshot: ShiftSnapshot?
    private(set) var profileName: String?
    private(set) var workSummary: WorkSummaryResponse?
    private(set) var isBusy = false
    private(set) var lastError: APIError? { didSet { updateMenuBar() } }
    private(set) var transientMessage: String?
    private(set) var pendingConfirmation: BreakRegulationInfo?
    private(set) var lastRefresh: Date?
    private(set) var hasToken: Bool { didSet { updateMenuBar() } }
    private(set) var now: Date
    private(set) var notificationsDenied = false
    /// Inline confirmation currently shown in the panel (Ausstempeln / Abbrechen).
    private(set) var pendingAction: PendingAction?

    // Menu bar label; assigned only when the value really changes.
    private(set) var menuBarText = ""
    private(set) var menuBarSymbol = "clock"
    private(set) var menuBarAccessibility = "Timebutler"

    var breakReminderEnabled: Bool {
        didSet {
            defaults.set(breakReminderEnabled, forKey: Self.reminderEnabledKey)
            guard breakReminderEnabled != oldValue else { return }
            if breakReminderEnabled, let scheduler {
                Task { notificationsDenied = !(await scheduler.requestAuthorization()) }
            }
            updateReminders()
        }
    }

    // MARK: Dependencies and internals

    static let reminderEnabledKey = "breakReminderEnabled"
    /// Request id -> planned fire date (seconds since 1970) of scheduled break reminders.
    static let reminderLedgerKey = "scheduledBreakReminders"

    @ObservationIgnored private let api: any TimeClockAPI
    @ObservationIgnored private let tokenStore: any TokenStore
    @ObservationIgnored private let tokenCache: TokenCache
    @ObservationIgnored private let scheduler: (any ReminderScheduler)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let nowProvider: @MainActor () -> Date

    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var reminderTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var summaryDay: Date?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    init(
        api: any TimeClockAPI,
        tokenStore: any TokenStore,
        tokenCache: TokenCache = TokenCache(),
        scheduler: (any ReminderScheduler)? = nil,
        defaults: UserDefaults = .standard,
        nowProvider: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.tokenCache = tokenCache
        self.scheduler = scheduler
        self.defaults = defaults
        self.nowProvider = nowProvider
        self.now = nowProvider()
        self.breakReminderEnabled = defaults.object(forKey: Self.reminderEnabledKey) as? Bool ?? true

        var initialError: APIError?
        do {
            tokenCache.token = try tokenStore.readToken()
        } catch {
            initialError = .keychain(String(describing: error))
        }
        self.hasToken = tokenCache.token != nil
        self.lastError = initialError
        updateMenuBar()
    }

    /// "tb_••••1234" for display in the settings.
    var maskedToken: String? {
        guard let token = tokenCache.token else { return nil }
        return "tb_••••" + token.suffix(4)
    }

    var needsSetup: Bool { !hasToken || lastError == .unauthorized }

    // MARK: Lifecycle

    /// Starts polling and ticking. Idempotent. Not called by unit tests.
    func start() {
        guard !started else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        restartTicker()
        pollTask = Task { await runPolling() }
    }

    func panelDidAppear() {
        guard !panelVisible else { return }
        panelVisible = true
        tick()
        restartTicker()
        Task { await refreshAll() }
    }

    func panelDidDisappear() {
        panelVisible = false
        pendingAction = nil
        restartTicker()
    }

    private func handleWake() {
        tick()
        Task { await refreshAll() }
    }

    // MARK: Ticking

    /// Updates `now` and everything derived from it.
    func tick() {
        now = nowProvider()
        updateMenuBar()
        // The work summary covers "today" only, so refetch when the calendar day changes.
        if hasToken, let summaryDay, !Calendar.current.isDate(summaryDay, inSameDayAs: now) {
            self.summaryDay = now
            Task { await refreshWorkSummary() }
        }
        if let snapshot, snapshot.isActive, snapshot.isStale(at: now), statusTask == nil {
            Task { await refreshStatus(reportErrors: false) }
        }
    }

    private func restartTicker() {
        tickerTask?.cancel()
        tickerTask = Task { await runTicker() }
    }

    private func runTicker() async {
        while !Task.isCancelled {
            // Open panel: every second. Closed: only when the label text would change.
            let delay: TimeInterval = panelVisible
                ? 1
                : min(60, (snapshot?.secondsUntilLabelChange(at: nowProvider()) ?? 60) + 0.05)
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { break }
            tick()
        }
    }

    private func runPolling() async {
        await refreshAll()
        var cycles = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { break }
            cycles += 1
            if lastError != .unauthorized { await refreshStatus(reportErrors: true) }
            if cycles % 10 == 0 { await refreshWorkSummary() }
        }
    }

    // MARK: Refreshing

    func refreshAll() async {
        await refreshStatus(reportErrors: true)
        await refreshWorkSummary()
        if profileName == nil { await refreshProfile() }
    }

    /// User-triggered refresh (button, "Erneut versuchen").
    func manualRefresh() async {
        lastError = nil
        await refreshAll()
    }

    /// Fetches the status. Concurrent calls are coalesced into one request.
    func refreshStatus(reportErrors: Bool) async {
        if let statusTask {
            await statusTask.value
            return
        }
        let task = Task { await fetchStatus(reportErrors: reportErrors) }
        statusTask = task
        await task.value
        statusTask = nil
    }

    private func fetchStatus(reportErrors: Bool) async {
        guard hasToken else { return }
        do {
            applySnapshot(try await api.status())
            lastRefresh = nowProvider()
            retryAttempt = 0
            if lastError?.isConnectivityRelated == true { lastError = nil }
        } catch {
            guard let apiError = Self.normalize(error) else { return }
            if reportErrors { lastError = apiError }
            if apiError.isConnectivityRelated { scheduleRetry() }
        }
    }

    func refreshWorkSummary() async {
        guard hasToken else { return }
        summaryDay = nowProvider()
        if let summary = try? await api.workSummary() { workSummary = summary }
    }

    func refreshProfile() async {
        guard hasToken else { return }
        if let profile = try? await api.profile(token: nil) { profileName = profile.name }
    }

    /// Retries the status request with exponential backoff (5 s up to 60 s). Only while running.
    private func scheduleRetry() {
        guard started else { return }
        retryTask?.cancel()
        let delay = min(5 * pow(2, Double(retryAttempt)), 60)
        retryAttempt += 1
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await refreshStatus(reportErrors: false)
        }
    }

    // MARK: Actions

    func clockIn() async {
        await perform { applySnapshot(try await api.start()) }
    }

    func startBreak() async {
        await perform { applySnapshot(try await api.pause()) }
    }

    func endBreak() async {
        await perform { applySnapshot(try await api.resume()) }
    }

    func requestClockOut() { pendingAction = .clockOut }
    func requestCancel() { pendingAction = .cancel }

    /// "Zurück" on any inline confirmation. Nothing is sent; the shift keeps running.
    func dismissConfirmation() {
        pendingAction = nil
        pendingConfirmation = nil
    }

    func dismissError() { lastError = nil }

    func clockOut() async {
        pendingAction = nil
        await stop(breakRegulation: nil)
    }

    func confirmClockOut(apply: Bool) async {
        await stop(breakRegulation: apply ? .apply : .ignore)
    }

    func cancelShift() async {
        pendingAction = nil
        await perform {
            applySnapshot(try await api.cancel())
            await refreshWorkSummary()
        }
    }

    private func stop(breakRegulation: BreakRegulation?) async {
        await perform {
            switch try await api.stop(breakRegulation: breakRegulation) {
            case .saved(let worked, let breakMinutes):
                pendingConfirmation = nil
                if let worked, let breakMinutes {
                    showTransient("Gespeichert: \(DurationFormatting.minutesHmm(worked)) h Arbeit, \(DurationFormatting.minutesHmm(breakMinutes)) h Pause")
                } else {
                    showTransient("Schicht gespeichert.")
                }
                await refreshStatus(reportErrors: false)
                await refreshWorkSummary()
            case .confirmationRequired(let info):
                pendingConfirmation = info
            case .discardedWhileWaiting:
                pendingConfirmation = nil
                showTransient("Schicht verworfen (Mindestintervall nicht erreicht)")
                await refreshStatus(reportErrors: false)
                await refreshWorkSummary()
            }
        }
    }

    /// Runs an API action with busy flag and uniform error handling: show the error, then resync,
    /// because the state may have been changed elsewhere (e.g. in the web UI).
    private func perform(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            guard let apiError = Self.normalize(error) else { return }
            lastError = apiError
            pendingConfirmation = nil
            pendingAction = nil
            await refreshStatus(reportErrors: false)
        }
    }

    // MARK: Token management

    /// Validates a candidate token against the API and stores it in the Keychain only on success.
    func connect(token candidate: String) async -> ConnectResult {
        let token = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failed(.noToken) }
        do {
            let profile = try await api.profile(token: token)
            do {
                try tokenStore.saveToken(token)
            } catch {
                return .failed(.keychain(String(describing: error)))
            }
            tokenCache.token = token
            hasToken = true
            lastError = nil
            profileName = profile.name
            await refreshStatus(reportErrors: true)
            await refreshWorkSummary()
            return .connected(name: profile.name ?? "Unbekannt", timeTrackingEnabled: profile.isTimeTrackingEnabled ?? true)
        } catch {
            guard let apiError = Self.normalize(error) else { return .failed(.network(.cancelled)) }
            return apiError == .unauthorized ? .invalid : .failed(apiError)
        }
    }

    func removeToken() {
        do {
            try tokenStore.deleteToken()
        } catch {
            lastError = .keychain(String(describing: error))
            return
        }
        tokenCache.token = nil
        retryTask?.cancel()
        snapshot = nil
        profileName = nil
        workSummary = nil
        pendingConfirmation = nil
        pendingAction = nil
        lastError = nil
        hasToken = false
        updateReminders()
        updateMenuBar()
        updateActivity()
    }

    // MARK: Derived state

    private func applySnapshot(_ dto: TimeClockStatusDto) {
        now = nowProvider()
        snapshot = ShiftSnapshot(dto: dto, fetchedAt: now)
        updateMenuBar()
        updateReminders()
        updateActivity()
        // The closed-panel ticker sleeps until the next label change; re-arm it for the new snapshot.
        if started { restartTicker() }
    }

    /// Keeps the process out of App Nap while a shift is shown, so label updates are not coalesced.
    private func updateActivity() {
        guard started else { return }
        let needed = hasToken && snapshot?.isActive == true
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Laufende Schicht anzeigen"
            )
        } else if !needed, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    private func updateMenuBar() {
        let symbol: String
        var text = ""
        let accessibility: String
        if needsSetup {
            symbol = "clock.badge.exclamationmark"
            accessibility = "Timebutler: Token fehlt oder ist ungültig"
        } else if let snapshot, snapshot.isActive {
            let net = snapshot.netWork(at: now)
            text = DurationFormatting.hmm(net)
            switch snapshot.status {
            case .running: symbol = "clock.fill"
            case .paused: symbol = "pause.circle.fill"
            default: symbol = "hourglass"
            }
            accessibility = "Timebutler: \(snapshot.status.displayName.lowercased()), \(DurationFormatting.spoken(net))"
        } else {
            symbol = "clock"
            accessibility = snapshot?.status == .idle ? "Timebutler: nicht eingestempelt" : "Timebutler"
        }
        if menuBarSymbol != symbol { menuBarSymbol = symbol }
        if menuBarText != text { menuBarText = text }
        if menuBarAccessibility != accessibility { menuBarAccessibility = accessibility }
    }

    private func showTransient(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            transientMessage = nil
        }
    }

    private func updateReminders() {
        guard let scheduler else { return }
        let previous = reminderTask
        reminderTask = Task {
            await previous?.value
            let pending = await scheduler.pendingIdentifiers()
            let current = nowProvider()
            let stored = defaults.dictionary(forKey: Self.reminderLedgerKey) as? [String: Double] ?? [:]
            let ledger = stored.mapValues { Date(timeIntervalSince1970: $0) }
            let delivered = BreakReminder.deliveredIDs(ledger: ledger, pending: pending, now: current)
            let plan = BreakReminder.plan(
                snapshot: snapshot, now: current, enabled: breakReminderEnabled, delivered: delivered
            )
            // Keep delivered entries and record the new plan; undelivered old entries are replaced.
            var newLedger = ledger.filter { delivered.contains($0.key) }
            for reminder in plan { newLedger[reminder.id] = current.addingTimeInterval(reminder.fireIn) }
            if let start = snapshot?.dto.startTimestamp, snapshot?.isActive == true {
                newLedger = newLedger.filter { $0.key.hasSuffix("-\(start)") }
                defaults.set(newLedger.mapValues(\.timeIntervalSince1970), forKey: Self.reminderLedgerKey)
            } else {
                defaults.removeObject(forKey: Self.reminderLedgerKey)
            }
            let allowed = await scheduler.apply(plan)
            if !plan.isEmpty { notificationsDenied = !allowed }
        }
    }

    /// Maps any thrown error to `APIError`; `nil` for cancellation.
    private static func normalize(_ error: any Error) -> APIError? {
        if error is CancellationError { return nil }
        return (error as? APIError) ?? .decoding
    }
}
