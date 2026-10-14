import Foundation
import Testing
@testable import TimebutlerToolbar

@MainActor
struct StoreTests {
    let api = MockTimeClockAPI()
    let tokens = InMemoryTokenStore(token: "tb_test1234")
    let scheduler = MockScheduler()
    let clock = TestClock()
    let defaults: UserDefaults

    init() {
        let suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(token: String? = "tb_test1234") -> ShiftStore {
        let clock = clock
        return ShiftStore(
            api: api, tokenStore: InMemoryTokenStore(token: token), tokenCache: TokenCache(),
            scheduler: scheduler, defaults: defaults, nowProvider: { clock.now }
        )
    }

    @Test func initReadsTokenAndShowsSetupWithoutOne() {
        #expect(makeStore().hasToken)
        #expect(makeStore().maskedToken == "tb_••••1234")
        let empty = makeStore(token: nil)
        #expect(empty.hasToken == false)
        #expect(empty.menuBarSymbol == "clock.badge.exclamationmark")
        #expect(empty.menuBarText.isEmpty)
    }

    @Test func clockInReplacesSnapshotAndLabel() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 0)) }
        await store.clockIn()
        #expect(store.snapshot?.status == .running)
        #expect(store.menuBarSymbol == "clock.fill")
        #expect(store.menuBarText == "0:00")
        #expect(store.isBusy == false)
        #expect(api.calls == ["start"])
    }

    @Test func labelFollowsClockOnTick() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 3 * 3600 + 41 * 60)) }
        await store.clockIn()
        #expect(store.menuBarText == "3:41")
        clock.now = clock.now.addingTimeInterval(90)
        store.tick()
        #expect(store.menuBarText == "3:42")
    }

    @Test func pausedLabelIsFrozenWithCoffeeSymbol() async {
        let store = makeStore()
        api.set { $0.pause = .success(makeDTO(.paused, work: 600, breakElapsed: 0)) }
        await store.startBreak()
        clock.now = clock.now.addingTimeInterval(300)
        store.tick()
        #expect(store.menuBarSymbol == "cup.and.heat.waves.fill")
        #expect(store.menuBarText == "0:10")
    }

    // MARK: Automatic break end

    @Test func autoBreakEndsOnlyWhenDue() async {
        let store = makeStore()
        api.set { $0.pause = .success(makeDTO(.paused, breakElapsed: 60)) }
        await store.startBreak(autoEndAfter: 30)
        #expect(store.autoBreakEnd == clock.now.addingTimeInterval(29 * 60))
        clock.now = clock.now.addingTimeInterval(29 * 60 - 1)
        store.tick()
        await store.endBreakIfDue()
        #expect(!api.calls.contains("resume"))
        #expect(scheduler.notified.isEmpty)
        clock.now = clock.now.addingTimeInterval(2)
        store.tick()
        await store.endBreakIfDue()
        #expect(api.calls.filter { $0 == "resume" }.count == 1)
        #expect(store.autoBreakEnd == nil)
        #expect(store.snapshot?.status == .running)
        #expect(scheduler.notified.count == 1)
        #expect(scheduler.notified.first?.title == "Pause beendet")
        #expect(scheduler.notified.first?.body.contains("nach 30 Min.") == true)
        #expect(scheduler.notified.first?.id.hasPrefix(BreakReminder.identifierPrefix) == false)
    }

    @Test func plainBreakHasNoAutoEnd() async {
        let store = makeStore()
        api.set { $0.pause = .success(makeDTO(.paused)) }
        await store.startBreak()
        #expect(store.autoBreakEnd == nil)
    }

    @Test func manualEndClearsAutoBreak() async {
        let store = makeStore()
        api.set { $0.pause = .success(makeDTO(.paused)) }
        await store.startBreak(autoEndAfter: 45)
        #expect(store.autoBreakEnd != nil)
        await store.endBreak()
        #expect(store.autoBreakEnd == nil)
    }

    @Test func refreshShowingRunningClearsAutoBreak() async {
        let store = makeStore()
        api.set { $0.pause = .success(makeDTO(.paused)) }
        await store.startBreak(autoEndAfter: 60)
        api.set { $0.status = [.success(makeDTO(.running))] }
        await store.refreshStatus(reportErrors: true)
        #expect(store.autoBreakEnd == nil)
    }

    @Test func autoBreakIsRestoredFromDefaults() async {
        let store = makeStore()
        api.set { $0.pause = .success(makeDTO(.paused)) }
        await store.startBreak(autoEndAfter: 30)
        let restored = makeStore()
        #expect(restored.autoBreakEnd == store.autoBreakEnd)
        #expect(restored.autoBreakEnd != nil)
    }

    @Test func nonConnectivityErrorDoesNotRetryAutoEnd() async {
        let store = makeStore()
        api.set {
            $0.pause = .success(makeDTO(.paused))
            $0.resume = .failure(.conflict(.resume))
            $0.status = [.success(makeDTO(.paused))]
        }
        await store.startBreak(autoEndAfter: 30)
        clock.now = clock.now.addingTimeInterval(31 * 60)
        store.tick()
        await store.endBreakIfDue()
        await store.endBreakIfDue()
        #expect(api.calls.filter { $0 == "resume" }.count == 1)
        #expect(store.autoBreakEnd == nil)
        #expect(scheduler.notified.isEmpty)
    }

    @Test func connectivityErrorKeepsAutoEndForRetry() async {
        let store = makeStore()
        api.set {
            $0.pause = .success(makeDTO(.paused))
            $0.resume = .failure(.network(.notConnectedToInternet))
            $0.status = [.failure(.network(.notConnectedToInternet))]
        }
        await store.startBreak(autoEndAfter: 30)
        let end = store.autoBreakEnd
        clock.now = clock.now.addingTimeInterval(31 * 60)
        store.tick()
        await store.endBreakIfDue()
        #expect(store.autoBreakEnd == end)
    }

    @Test func disablingAutoBreakClearsPendingEnd() async {
        let store = makeStore()
        #expect(store.autoBreakEnabled == false)
        store.autoBreakEnabled = true
        api.set { $0.pause = .success(makeDTO(.paused)) }
        await store.startBreak(autoEndAfter: 30)
        #expect(store.autoBreakEnd != nil)
        store.autoBreakEnabled = false
        #expect(store.autoBreakEnd == nil)
    }

    @Test func conflictShowsMessageAndRefreshesStatus() async {
        let store = makeStore()
        api.set {
            $0.start = .failure(.conflict(.start))
            $0.status = [.success(makeDTO(.running, work: 120))]
        }
        await store.clockIn()
        #expect(store.lastError == .conflict(.start))
        #expect(store.lastError?.message == "Die Stempeluhr läuft bereits.")
        #expect(api.calls == ["start", "status"])
        #expect(store.snapshot?.status == .running)
    }

    @Test func unauthorizedFlipsToSetupState() async {
        let store = makeStore()
        api.set { $0.status = [.failure(.unauthorized)] }
        await store.refreshStatus(reportErrors: true)
        #expect(store.lastError == .unauthorized)
        #expect(store.needsSetup)
        #expect(store.menuBarSymbol == "clock.badge.exclamationmark")
    }

    @Test func networkErrorKeepsLastKnownValue() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 3600)) }
        await store.clockIn()
        api.set { $0.status = [.failure(.network(.timedOut))] }
        await store.refreshStatus(reportErrors: true)
        #expect(store.lastError == .network(.timedOut))
        #expect(store.menuBarText == "1:00")
        #expect(store.menuBarSymbol == "clock.fill")
    }

    @Test func concurrentStatusRequestsAreCoalesced() async {
        let store = makeStore()
        api.set { $0.statusDelay = .milliseconds(100) }
        async let a: Void = store.refreshStatus(reportErrors: true)
        async let b: Void = store.refreshStatus(reportErrors: true)
        _ = await (a, b)
        #expect(api.calls.filter { $0 == "status" }.count == 1)
    }

    @Test func successfulRefreshClearsConnectivityError() async {
        let store = makeStore()
        api.set { $0.status = [.failure(.network(.timedOut))] }
        await store.refreshStatus(reportErrors: true)
        api.set { $0.status = [.success(makeDTO(.idle))] }
        await store.refreshStatus(reportErrors: true)
        #expect(store.lastError == nil)
        #expect(store.lastRefresh != nil)
    }

    // MARK: Stop flow

    @Test func stopSavedShowsSummaryAndRefreshes() async {
        let store = makeStore()
        api.set {
            $0.stop = [.success(.saved(workedMinutes: 452, breakMinutes: 45))]
            $0.status = [.success(makeDTO(.idle))]
        }
        store.requestClockOut()
        #expect(store.pendingAction == .clockOut)
        await store.clockOut()
        #expect(store.pendingAction == nil)
        #expect(store.transientMessage == "Gespeichert: 7:32 h Arbeit, 0:45 h Pause")
        #expect(api.calls == ["stop:none", "status", "summary", "entries"])
        #expect(store.snapshot?.status == .idle)
    }

    @Test func stopConfirmationThenApply() async {
        let store = makeStore()
        let info = BreakRegulationInfo(obligatory: true, resultingWorkMinutes: 400, resultingBreakMinutes: 30, detailText: "Pause")
        api.set {
            $0.stop = [.success(.confirmationRequired(info)), .success(.saved(workedMinutes: 400, breakMinutes: 30))]
        }
        await store.clockOut()
        #expect(store.pendingConfirmation == info)
        #expect(api.calls == ["stop:none"])

        await store.confirmClockOut(apply: true)
        #expect(store.pendingConfirmation == nil)
        #expect(api.calls.first(where: { $0.hasPrefix("stop") && $0 != "stop:none" }) == "stop:apply")
        #expect(store.transientMessage == "Gespeichert: 6:40 h Arbeit, 0:30 h Pause")
    }

    @Test func stopConfirmationBackSendsNothing() async {
        let store = makeStore()
        api.set { $0.stop = [.success(.confirmationRequired(BreakRegulationInfo(obligatory: false)))] }
        await store.clockOut()
        store.dismissConfirmation()
        #expect(store.pendingConfirmation == nil)
        #expect(api.calls == ["stop:none"])
    }

    @Test func stopDiscardedWhileWaiting() async {
        let store = makeStore()
        api.set { $0.stop = [.success(.discardedWhileWaiting)] }
        await store.clockOut()
        #expect(store.transientMessage == "Schicht verworfen (Mindestintervall nicht erreicht)")
        #expect(api.calls.contains("status"))
    }

    @Test func stopConflictShowsMessageAndRefreshes() async {
        let store = makeStore()
        api.set { $0.stop = [.failure(.conflict(.stop))] }
        await store.clockOut()
        #expect(store.lastError == .conflict(.stop))
        #expect(api.calls == ["stop:none", "status"])
    }

    @Test func cancelShiftDiscardsAndRefreshesSummary() async {
        let store = makeStore()
        await store.cancelShift()
        #expect(api.calls == ["cancel", "summary", "entries"])
        #expect(store.snapshot?.status == .idle)
    }

    // MARK: Token

    @Test func connectSavesOnlyValidTokens() async {
        let tokens = InMemoryTokenStore()
        let clock = clock
        let store = ShiftStore(
            api: api, tokenStore: tokens, tokenCache: TokenCache(),
            scheduler: nil, defaults: defaults, nowProvider: { clock.now }
        )
        api.set { $0.profile = .failure(.unauthorized) }
        #expect(await store.connect(token: "tb_bad") == .invalid)
        #expect(tokens.current == nil)
        #expect(store.hasToken == false)

        api.set { $0.profile = .success(UserProfileResponse(name: "Max", isTimeTrackingEnabled: false)) }
        #expect(await store.connect(token: "  tb_good1234\n") == .connected(name: "Max", timeTrackingEnabled: false))
        #expect(tokens.current == "tb_good1234")
        #expect(store.hasToken)
        #expect(store.profileName == "Max")
        #expect(api.calls.contains("profile:tb_good1234"))
    }

    @Test func connectNetworkFailureDoesNotSave() async {
        let tokens = InMemoryTokenStore()
        let clock = clock
        let store = ShiftStore(api: api, tokenStore: tokens, scheduler: nil, defaults: defaults, nowProvider: { clock.now })
        api.set { $0.profile = .failure(.network(.notConnectedToInternet)) }
        #expect(await store.connect(token: "tb_x") == .failed(.network(.notConnectedToInternet)))
        #expect(tokens.current == nil)
    }

    @Test func removeTokenResetsState() async {
        let store = makeStore()
        await store.clockIn()
        store.removeToken()
        #expect(store.hasToken == false)
        #expect(store.snapshot == nil)
        #expect(store.menuBarSymbol == "clock.badge.exclamationmark")
    }

    // MARK: Reminders

    /// Lets the store's serial reminder task finish.
    private func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    @Test func reminderSurvivesSleepOverFireTime() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 5 * 3600 + 30 * 60)) }
        await store.clockIn()
        await settle()
        #expect(scheduler.applied.last?.first?.fireIn == 900.0)

        // Mac sleeps past the fire time; the request is still pending (undelivered) on wake.
        clock.now = clock.now.addingTimeInterval(20 * 60)
        api.set { $0.status = [.success(makeDTO(.running, work: 5 * 3600 + 50 * 60))] }
        await store.refreshStatus(reportErrors: true)
        await settle()
        let sixHour = scheduler.applied.last?.first { $0.id.hasPrefix("break-6h") }
        #expect(sixHour?.fireIn == 1)
    }

    @Test func deliveredReminderIsNotRepeated() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 5 * 3600 + 30 * 60)) }
        await store.clockIn()
        await settle()
        clock.now = clock.now.addingTimeInterval(20 * 60)
        scheduler.pending = []   // the system delivered it
        api.set { $0.status = [.success(makeDTO(.running, work: 5 * 3600 + 50 * 60))] }
        await store.refreshStatus(reportErrors: true)
        await settle()
        #expect(scheduler.applied.last?.contains { $0.id.hasPrefix("break-6h") } == false)
    }

    @Test func pauseBeforeLeadPointThenResumeAfterItFiresImmediately() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 5 * 3600 + 40 * 60)) }
        await store.clockIn()
        await settle()
        api.set { $0.pause = .success(makeDTO(.paused, work: 5 * 3600 + 40 * 60)) }
        await store.startBreak()
        await settle()
        #expect(scheduler.applied.last?.isEmpty == true)

        // Break lasts long enough that the original fire date lies in the past.
        clock.now = clock.now.addingTimeInterval(30 * 60)
        api.set { $0.resume = .success(makeDTO(.running, work: 5 * 3600 + 50 * 60, accumulated: 10 * 60)) }
        await store.endBreak()
        await settle()
        #expect(scheduler.applied.last?.first { $0.id.hasPrefix("break-6h") }?.fireIn == 1)
    }

    @Test func dayRolloverRefreshesWorkSummary() async {
        let store = makeStore()
        await store.refreshWorkSummary()
        #expect(api.calls.filter { $0 == "summary" }.count == 1)
        store.tick()
        await settle()
        #expect(api.calls.filter { $0 == "summary" }.count == 1)
        clock.now = clock.now.addingTimeInterval(2 * 24 * 3600)
        store.tick()
        await settle()
        #expect(api.calls.filter { $0 == "summary" }.count == 2)
    }

    @Test func snapshotChangeSchedulesReminders() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 5 * 3600)) }
        await store.clockIn()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(scheduler.applied.last?.map(\.id) == ["break-6h-1000000", "break-9h-1000000", "shift-10h-1000000"])

        store.breakReminderEnabled = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(scheduler.applied.last?.map(\.id) == ["shift-10h-1000000"])

        store.maxWorkReminderEnabled = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(scheduler.applied.last?.isEmpty == true)
    }

    @Test func workSummaryAddsTargetReminder() async {
        let store = makeStore()
        api.set { $0.start = .success(makeDTO(.running, work: 3600)) }
        await store.clockIn()
        await store.refreshWorkSummary()
        await settle()
        // Mock summary: 420 min target, 100 min saved; 60 min in this shift.
        let target = scheduler.applied.last?.first { $0.id == "shift-target-1000000" }
        #expect(target?.fireIn == TimeInterval((420 - 100 - 60) * 60))
    }
}
