import Foundation

/// A status response plus the local time it arrived. All live values are derived with a monotonic
/// delta from `fetchedAt`, so they are immune to clock skew between this Mac and the server.
struct ShiftSnapshot: Sendable, Equatable {
    /// After this gap (e.g. after sleep) the values must not be trusted without a refetch.
    static let staleAfter: TimeInterval = 10 * 60

    let dto: TimeClockStatusDto
    let fetchedAt: Date

    var status: ClockStatus { dto.status }
    var isActive: Bool { [.running, .paused, .waiting].contains(status) }

    func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(fetchedAt)) }

    /// Net working time (breaks excluded).
    func netWork(at now: Date) -> TimeInterval {
        let base = TimeInterval(dto.workTimeElapsedSeconds ?? 0)
        switch status {
        case .running: return base + elapsed(at: now)
        case .paused, .waiting: return base
        case .idle, .unknown: return 0
        }
    }

    /// Length of the current break. `breakElapsedSeconds` is stale after resuming, so it is only used while paused.
    func currentBreak(at now: Date) -> TimeInterval {
        status == .paused ? TimeInterval(dto.breakElapsedSeconds ?? 0) + elapsed(at: now) : 0
    }

    func totalBreak(at now: Date) -> TimeInterval {
        TimeInterval(dto.accumulatedBreakSeconds ?? 0) + currentBreak(at: now)
    }

    func gross(at now: Date) -> TimeInterval { netWork(at: now) + totalBreak(at: now) }

    var shiftStart: Date? { dto.startTimestamp.map(Self.date(fromMillis:)) }
    var breakStart: Date? { status == .paused ? dto.pauseTimestamp.map(Self.date(fromMillis:)) : nil }

    /// Remaining wait countdown, if the server reported one.
    func waitRemaining(at now: Date) -> TimeInterval? {
        guard let wait = dto.waitSeconds, wait > 0 else { return nil }
        let remaining = TimeInterval(wait) - elapsed(at: now)
        return remaining > 0 ? remaining : nil
    }

    func isStale(at now: Date) -> Bool { elapsed(at: now) > Self.staleAfter }

    /// Seconds until `hmm(netWork)` shows a different value; `nil` when the net time is not advancing.
    func secondsUntilLabelChange(at now: Date) -> TimeInterval? {
        guard status == .running else { return nil }
        let net = netWork(at: now)
        return 60 - net.truncatingRemainder(dividingBy: 60)
    }

    private static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}

/// "Heute" totals: saved entries from the work summary plus the running session.
struct TodayTotals: Equatable {
    let workedSeconds: TimeInterval
    let targetSeconds: TimeInterval
    let breakSeconds: TimeInterval

    init?(summary: WorkSummaryResponse?, snapshot: ShiftSnapshot?, now: Date) {
        guard let summary else { return nil }
        workedSeconds = TimeInterval((summary.workedMinutes ?? 0) * 60) + (snapshot?.netWork(at: now) ?? 0)
        targetSeconds = TimeInterval((summary.commitmentMinutes ?? 0) * 60)
        breakSeconds = TimeInterval((summary.breakMinutes ?? 0) * 60) + (snapshot?.totalBreak(at: now) ?? 0)
    }

    var remainingSeconds: TimeInterval { max(0, targetSeconds - workedSeconds) }
    var overtimeSeconds: TimeInterval { max(0, workedSeconds - targetSeconds) }
    var progress: Double { targetSeconds > 0 ? min(1, workedSeconds / targetSeconds) : 0 }
}
