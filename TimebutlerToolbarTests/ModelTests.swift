import Foundation
import Testing
@testable import TimebutlerToolbar

struct DecodingTests {
    @Test func runningSample() throws {
        let dto: TimeClockStatusDto = try Fixtures.decode(Fixtures.running)
        #expect(dto.status == .running)
        #expect(dto.startTimestamp == 1791911608634)
        #expect(dto.workTimeElapsedSeconds == 60)
        #expect(dto.pauseTimestamp == nil)
        #expect(dto.waitSeconds == nil)
        #expect(dto.startOnlyOnTerminal == false)
    }

    @Test func pausedSample() throws {
        let dto: TimeClockStatusDto = try Fixtures.decode(Fixtures.paused)
        #expect(dto.status == .paused)
        #expect(dto.pauseTimestamp == 1791911719831)
        #expect(dto.breakElapsedSeconds == 11)
    }

    @Test func resumedSample() throws {
        let dto: TimeClockStatusDto = try Fixtures.decode(Fixtures.resumed)
        #expect(dto.accumulatedBreakSeconds == 44)
        #expect(dto.breakElapsedSeconds == 44)
    }

    @Test func idleWithOmittedFields() throws {
        let dto: TimeClockStatusDto = try Fixtures.decode(Fixtures.idle)
        #expect(dto.status == .idle)
        #expect(dto.startTimestamp == nil)
        #expect(dto.workTimeElapsedSeconds == nil)
    }

    @Test func unknownStatusAndMissingStatus() throws {
        let unknown: TimeClockStatusDto = try Fixtures.decode(#"{"status":"vacation"}"#)
        #expect(unknown.status == .unknown)
        let missing: TimeClockStatusDto = try Fixtures.decode("{}")
        #expect(missing.status == .unknown)
    }

    @Test func summaryAndProfile() throws {
        let summary: WorkSummaryResponse = try Fixtures.decode(Fixtures.summary)
        #expect(summary.workedMinutes == 467)
        #expect(summary.breakMinutes == 90)
        let profile: UserProfileResponse = try Fixtures.decode(Fixtures.profile)
        #expect(profile.name == "Max Mustermann")
        #expect(profile.isTimeTrackingEnabled == true)
    }

    @Test func stopResponses() throws {
        let saved: TimeClockStopResponse = try Fixtures.decode(#"{"outcome":"saved","id":"1","workedMinutes":452,"breakMinutes":45}"#)
        #expect(saved.outcome == .saved)
        #expect(saved.workedMinutes == 452)
        let confirm: TimeClockStopResponse = try Fixtures.decode(#"{"outcome":"confirmationRequired","breakRegulation":{"obligatory":true,"resultingWorkMinutes":400,"resultingBreakMinutes":30,"detailText":"Text"}}"#)
        #expect(confirm.outcome == .confirmationRequired)
        #expect(confirm.breakRegulation?.obligatory == true)
        #expect(confirm.breakRegulation?.hasNoRemedy == nil)
        let unknown: TimeClockStopResponse = try Fixtures.decode(#"{"outcome":"weird"}"#)
        #expect(unknown.outcome == .unknown)
    }
}

struct SnapshotTests {
    @Test func runningAdvancesWithElapsedTime() {
        let s = makeSnapshot(makeDTO(.running, work: 60))
        let now = referenceDate.addingTimeInterval(30)
        #expect(s.netWork(at: now) == 90)
        #expect(s.currentBreak(at: now) == 0)
        #expect(s.gross(at: now) == 90)
    }

    @Test func pausedFreezesWorkAndGrowsBreak() {
        let s = makeSnapshot(makeDTO(.paused, work: 111, breakElapsed: 11, accumulated: 20))
        let now = referenceDate.addingTimeInterval(10)
        #expect(s.netWork(at: now) == 111)
        #expect(s.currentBreak(at: now) == 21)
        #expect(s.totalBreak(at: now) == 41)
        #expect(s.gross(at: now) == 152)
    }

    @Test func afterResumeIgnoresStaleBreakElapsed() {
        let s = makeSnapshot(makeDTO(.running, work: 149, breakElapsed: 44, accumulated: 44))
        let now = referenceDate.addingTimeInterval(5)
        #expect(s.currentBreak(at: now) == 0)
        #expect(s.totalBreak(at: now) == 44)
        #expect(s.netWork(at: now) == 154)
        #expect(s.gross(at: now) == 198)
    }

    @Test func idleIsZero() {
        let s = makeSnapshot(makeDTO(.idle, work: 500, start: nil))
        #expect(s.netWork(at: referenceDate.addingTimeInterval(100)) == 0)
        #expect(s.isActive == false)
        #expect(s.shiftStart == nil)
    }

    @Test func waitingIsFrozenWithCountdown() {
        let s = makeSnapshot(makeDTO(.waiting, work: 30, wait: 120))
        let now = referenceDate.addingTimeInterval(20)
        #expect(s.netWork(at: now) == 30)
        #expect(s.waitRemaining(at: now) == 100)
        #expect(s.waitRemaining(at: referenceDate.addingTimeInterval(500)) == nil)
    }

    @Test func clockGoingBackwardsDoesNotProduceNegativeDelta() {
        let s = makeSnapshot(makeDTO(.running, work: 60))
        #expect(s.netWork(at: referenceDate.addingTimeInterval(-50)) == 60)
    }

    @Test func timestampsAndStaleness() {
        let s = makeSnapshot(makeDTO(.paused, start: 1791911608634, pause: 1791911719831))
        #expect(s.shiftStart == Date(timeIntervalSince1970: 1791911608.634))
        #expect(s.breakStart == Date(timeIntervalSince1970: 1791911719.831))
        #expect(s.isStale(at: referenceDate.addingTimeInterval(599)) == false)
        #expect(s.isStale(at: referenceDate.addingTimeInterval(601)))
        #expect(makeSnapshot(makeDTO(.running)).breakStart == nil)
    }

    @Test func labelChangeTiming() {
        let s = makeSnapshot(makeDTO(.running, work: 3 * 3600 + 41 * 60 + 45))
        #expect(s.secondsUntilLabelChange(at: referenceDate) == 15)
        #expect(makeSnapshot(makeDTO(.paused, work: 10)).secondsUntilLabelChange(at: referenceDate) == nil)
    }

    @Test func todayTotals() throws {
        let summary = WorkSummaryResponse(commitmentMinutes: 420, workedMinutes: 300, breakMinutes: 30)
        let s = makeSnapshot(makeDTO(.running, work: 1800, accumulated: 600))
        let totals = try #require(TodayTotals(summary: summary, snapshot: s, now: referenceDate))
        #expect(totals.workedSeconds == 300 * 60 + 1800)
        #expect(totals.breakSeconds == 30 * 60 + 600)
        #expect(totals.remainingSeconds == 420 * 60 - 300 * 60 - 1800)
        #expect(totals.overtimeSeconds == 0)
        let over = try #require(TodayTotals(summary: WorkSummaryResponse(commitmentMinutes: 420, workedMinutes: 467), snapshot: nil, now: referenceDate))
        #expect(over.overtimeSeconds == 47 * 60)
        #expect(TodayTotals(summary: nil, snapshot: s, now: referenceDate) == nil)
    }
}

struct FormattingTests {
    @Test func hmm() {
        #expect(DurationFormatting.hmm(0) == "0:00")
        #expect(DurationFormatting.hmm(59.9) == "0:00")
        #expect(DurationFormatting.hmm(3 * 3600 + 42 * 60 + 59) == "3:42")
        #expect(DurationFormatting.hmm(10 * 3600 + 5 * 60) == "10:05")
        #expect(DurationFormatting.hmm(-5) == "0:00")
    }

    @Test func hmmss() {
        #expect(DurationFormatting.hmmss(3 * 3600 + 42 * 60 + 7) == "3:42:07")
        #expect(DurationFormatting.hmmss(61.9) == "0:01:01")
    }

    @Test func minutesAndBreak() {
        #expect(DurationFormatting.minutesHmm(452) == "7:32")
        #expect(DurationFormatting.minutesHmm(45) == "0:45")
        #expect(DurationFormatting.mss(125) == "2:05")
    }

    @Test func spoken() {
        #expect(DurationFormatting.spoken(3 * 3600 + 42 * 60) == "3 Stunden 42 Minuten")
        #expect(DurationFormatting.spoken(3600 + 60) == "1 Stunde 1 Minute")
    }

    @Test func clockTimeUsesTwoDigitsAndMatchesLocalTime() {
        let text = DurationFormatting.clockTime(referenceDate)
        #expect(text.contains(":"))
        #expect(text.count >= 5)
    }
}

struct ReminderPlanTests {
    private func plan(_ dto: TimeClockStatusDto, enabled: Bool = true, delivered: Set<String> = []) -> [ScheduledReminder] {
        BreakReminder.plan(snapshot: makeSnapshot(dto), now: referenceDate, enabled: enabled, delivered: delivered)
    }

    @Test func schedulesBothThresholdsEarlyInShift() {
        let result = plan(makeDTO(.running, work: 5 * 3600))
        #expect(result.map(\.id) == ["break-6h-1000000", "break-9h-1000000"])
        #expect(result[0].fireIn == 45 * 60)
        #expect(result[1].fireIn == 9 * 3600 - 900 - 5 * 3600)
        #expect(result[0].body == "In 15 Minuten erreichst du 6 Stunden Arbeitszeit. Bisher erfasst: 0 Min. Pause – nötig sind 30 Min.")
    }

    @Test func enoughBreakSuppressesReminder() {
        let result = plan(makeDTO(.running, work: 5 * 3600, accumulated: 30 * 60))
        #expect(result.map(\.id) == ["break-9h-1000000"])
        #expect(plan(makeDTO(.running, work: 5 * 3600, accumulated: 45 * 60)).isEmpty)
    }

    @Test func notScheduledWhenPausedIdleOrDisabled() {
        #expect(plan(makeDTO(.paused, work: 5 * 3600)).isEmpty)
        #expect(plan(makeDTO(.idle)).isEmpty)
        #expect(plan(makeDTO(.running, work: 3600), enabled: false).isEmpty)
        #expect(BreakReminder.plan(snapshot: nil, now: referenceDate, enabled: true, delivered: []).isEmpty)
    }

    @Test func leadPointPassedFiresImmediatelyOnce() throws {
        let dto = makeDTO(.running, work: 5 * 3600 + 50 * 60)
        let first = plan(dto)
        let six = try #require(first.first { $0.id == "break-6h-1000000" })
        #expect(six.fireIn == 1)
        #expect(six.body.hasPrefix("In 10 Minuten"))
        let second = plan(dto, delivered: [six.id])
        #expect(second.contains { $0.id == six.id } == false)
    }

    @Test func thresholdAlreadyReachedIsSkipped() {
        #expect(plan(makeDTO(.running, work: 6 * 3600 + 1)).map(\.id) == ["break-9h-1000000"])
        #expect(plan(makeDTO(.running, work: 9 * 3600)).isEmpty)
    }

    @Test func deliveredOnlyWhenFireDatePassedAndNoLongerPending() {
        let past = referenceDate.addingTimeInterval(-10)
        let future = referenceDate.addingTimeInterval(10)
        let ledger = ["a": past, "b": past, "c": future]
        // "a" fired and left the pending list; "b" is still pending (slept over fire time); "c" not due yet.
        let delivered = BreakReminder.deliveredIDs(ledger: ledger, pending: ["b", "c"], now: referenceDate)
        #expect(delivered == ["a"])
    }

    @Test func includesElapsedTimeSinceFetch() {
        let snapshot = makeSnapshot(makeDTO(.running, work: 5 * 3600))
        let result = BreakReminder.plan(snapshot: snapshot, now: referenceDate.addingTimeInterval(600), enabled: true, delivered: [])
        #expect(result[0].fireIn == 35 * 60)
    }
}

struct ShiftEndPlanTests {
    private func plan(
        _ dto: TimeClockStatusDto, worked: Int = 0, target: Int? = 480,
        targetEnabled: Bool = true, maxEnabled: Bool = true, delivered: Set<String> = []
    ) -> [ScheduledReminder] {
        ShiftEndReminder.plan(
            snapshot: makeSnapshot(dto), summary: WorkSummaryResponse(commitmentMinutes: target, workedMinutes: worked),
            now: referenceDate, targetEnabled: targetEnabled, maxEnabled: maxEnabled, delivered: delivered
        )
    }

    @Test func schedulesTargetAndMaxCountingSavedWork() {
        let result = plan(makeDTO(.running, work: 3 * 3600), worked: 120)
        #expect(result.map(\.id) == ["shift-target-1000000", "shift-10h-1000000"])
        #expect(result[0].fireIn == 3 * 3600)
        #expect(result[0].body == "Du hast dein Soll von 8:00 h für heute erreicht und kannst ausstempeln.")
        #expect(result[1].fireIn == 10 * 3600 - 900 - 5 * 3600)
        #expect(result[1].body.hasPrefix("In 15 Minuten erreichst du 10 Stunden"))
    }

    @Test func targetMetBeforeShiftOrMissingIsSkipped() {
        #expect(plan(makeDTO(.running, work: 600), worked: 480).map(\.id) == ["shift-10h-1000000"])
        #expect(plan(makeDTO(.running, work: 600), target: nil).map(\.id) == ["shift-10h-1000000"])
        #expect(plan(makeDTO(.running, work: 600), target: 0).map(\.id) == ["shift-10h-1000000"])
    }

    @Test func passedPointFiresImmediatelyOnce() throws {
        let dto = makeDTO(.running, work: 8 * 3600 + 60)
        let target = try #require(plan(dto).first { $0.id == "shift-target-1000000" })
        #expect(target.fireIn == 1)
        #expect(plan(dto, delivered: [target.id]).contains { $0.id == target.id } == false)
    }

    @Test func maxReachedIsSkipped() {
        #expect(plan(makeDTO(.running, work: 10 * 3600), target: nil).isEmpty)
    }

    @Test func notScheduledWhenPausedOrDisabled() {
        #expect(plan(makeDTO(.paused, work: 3600)).isEmpty)
        #expect(plan(makeDTO(.running, work: 3600), targetEnabled: false, maxEnabled: false).isEmpty)
        #expect(plan(makeDTO(.running, work: 3600), targetEnabled: false).map(\.id) == ["shift-10h-1000000"])
    }
}

struct DayTimelineTests {
    /// `referenceDate` is 2027-01-15 08:00 UTC.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Double) -> Date { referenceDate.addingTimeInterval((hour - 8) * 3600) }
    private func millis(_ hour: Double) -> Int64 { Int64(at(hour).timeIntervalSince1970 * 1000) }

    private func entry(_ start: String, _ end: String, pause: Int = 0, date: String = "2027-01-15", status: String = "done") -> TimeEntryDto {
        TimeEntryDto(date: date, startTime: start, endTime: end, breakMinutes: pause, status: status)
    }

    private func timeline(
        _ entries: [TimeEntryDto], _ dto: TimeClockStatusDto? = nil, now: Double, target: Int? = 420
    ) -> DayTimeline? {
        let current = at(now)
        return DayTimeline(
            entries: entries, snapshot: dto.map { makeSnapshot($0, fetchedAt: current) },
            summary: WorkSummaryResponse(commitmentMinutes: target), now: current, calendar: Self.calendar
        )
    }

    @Test func savedEntryGapAndRunningShift() throws {
        let t = try #require(timeline(
            [entry("08:00", "12:00", pause: 30)], makeDTO(.running, start: millis(12.5)), now: 15
        ))
        #expect(t.start == at(8))
        #expect(t.plannedEnd == at(15.5))   // 7 h + 30 min required break
        #expect(t.end == at(15.5))
        #expect(!t.isOverrun)
        #expect(t.segments == [
            .init(kind: .work, start: at(8), end: at(9.75)),
            .init(kind: .pause, start: at(9.75), end: at(10.25)),
            .init(kind: .work, start: at(10.25), end: at(12)),
            .init(kind: .untracked, start: at(12), end: at(12.5)),
            .init(kind: .work, start: at(12.5), end: at(15)),
        ])
    }

    @Test func overrunExtendsToNowWithMarker() throws {
        let t = try #require(timeline([], makeDTO(.running, start: millis(8)), now: 16))
        #expect(t.isOverrun)
        #expect(t.end == at(16))
        #expect(t.fraction(t.plannedEnd) == 7.5 / 8)
    }

    @Test func clockedOutEndsAtLastClockOut() throws {
        let t = try #require(timeline([entry("08:00", "17:00", pause: 30)], makeDTO(.idle), now: 20))
        #expect(t.end == at(17))
        #expect(t.isOverrun)
    }

    @Test func currentBreakIsExactAtTheEnd() throws {
        let t = try #require(timeline([], makeDTO(.paused, breakElapsed: 600, start: millis(8)), now: 12))
        #expect(t.segments == [
            .init(kind: .work, start: at(8), end: at(11) + 50 * 60),
            .init(kind: .pause, start: at(11) + 50 * 60, end: at(12)),
        ])
    }

    @Test func otherDaysRejectedAndNoTargetAreIgnored() {
        #expect(timeline([entry("08:00", "12:00", date: "2027-01-14")], now: 13) == nil)
        #expect(timeline([entry("08:00", "12:00", status: "rejected")], now: 13) == nil)
        #expect(timeline([entry("08:00", "12:00")], now: 13, target: nil) == nil)
        #expect(timeline([entry("08:00", "12:00")], now: 13, target: 0) == nil)
    }

    @Test func requiredBreakFollowsArbZG() {
        #expect(DayTimeline.requiredBreak(forWork: 6 * 3600) == 0)
        #expect(DayTimeline.requiredBreak(forWork: 7 * 3600) == 30 * 60)
        #expect(DayTimeline.requiredBreak(forWork: 9.5 * 3600) == 45 * 60)
    }
}
