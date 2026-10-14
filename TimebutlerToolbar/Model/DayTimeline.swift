import Foundation

/// Today from the first clock-in: work, breaks and untracked gaps, scaled to the planned day
/// (target work time plus the break the ArbZG requires for it).
///
/// The API only reports break sums per entry, not their position, so breaks of saved entries (and earlier
/// breaks of the running shift) are drawn in the middle of their block. Only the current break is exact.
struct DayTimeline: Equatable {
    enum Kind: Hashable { case work, pause, untracked }

    struct Segment: Equatable {
        let kind: Kind
        let start: Date
        let end: Date
    }

    let start: Date
    /// First clock-in + target work time + required break.
    let plannedEnd: Date
    /// Right edge: `plannedEnd`, or the last tracked moment (now, or the last clock-out) if that is later.
    let end: Date
    let segments: [Segment]

    /// Tracked time runs past the planned day; a marker is drawn at `plannedEnd`.
    var isOverrun: Bool { end > plannedEnd }

    /// Position of `date` on the bar, 0...1.
    func fraction(_ date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }

    /// `nil` without a target for today or before the first clock-in.
    init?(
        entries: [TimeEntryDto], snapshot: ShiftSnapshot?, summary: WorkSummaryResponse?,
        now: Date, calendar: Calendar = .current
    ) {
        guard let targetMinutes = summary?.commitmentMinutes, targetMinutes > 0 else { return nil }
        let target = TimeInterval(targetMinutes * 60)

        var blocks = Self.savedBlocks(entries: entries, now: now, calendar: calendar)
        let active = snapshot.flatMap { Self.activeBlock(snapshot: $0, now: now, calendar: calendar) }
        if let active {
            // The running shift is not a saved entry yet; drop a saved one starting at the same minute just in case.
            blocks.removeAll { abs($0.start.timeIntervalSince(active.start)) < 60 }
            blocks.append(active)
        }
        blocks.sort { $0.start < $1.start }
        guard let first = blocks.first else { return nil }

        var segments: [Segment] = []
        var cursor = first.start
        for block in blocks {
            if block.start > cursor {
                segments.append(Segment(kind: .untracked, start: cursor, end: block.start))
            }
            segments += block.segments
            cursor = max(cursor, block.end)
        }

        start = first.start
        plannedEnd = first.start.addingTimeInterval(target + Self.requiredBreak(forWork: target))
        // Clocked out: the bar ends at the last clock-out, not at now.
        end = max(plannedEnd, active != nil ? now : cursor)
        self.segments = segments
    }

    /// Break the ArbZG requires for the given work time (30 min above 6 h, 45 min above 9 h).
    static func requiredBreak(forWork work: TimeInterval) -> TimeInterval {
        BreakReminder.rules.filter { work > $0.threshold }.map(\.requiredBreak).max() ?? 0
    }

    // MARK: Blocks

    private struct Block {
        let start: Date
        let end: Date
        let segments: [Segment]
    }

    private static func savedBlocks(entries: [TimeEntryDto], now: Date, calendar: Calendar) -> [Block] {
        let today = dayString(now, calendar: calendar)
        return entries.compactMap { entry in
            guard entry.date == today, entry.status != "rejected",
                  let start = entry.startTime.flatMap({ time($0, on: now, calendar: calendar) }),
                  let end = entry.endTime.flatMap({ time($0, on: now, calendar: calendar) }),
                  end > start
            else { return nil }
            let pause = TimeInterval((entry.breakMinutes ?? 0) * 60)
            return Block(start: start, end: end, segments: centered(pause: pause, from: start, to: end))
        }
    }

    private static func activeBlock(snapshot: ShiftSnapshot, now: Date, calendar: Calendar) -> Block? {
        guard snapshot.isActive, let shiftStart = snapshot.shiftStart, shiftStart < now,
              calendar.isDate(shiftStart, inSameDayAs: now)
        else { return nil }
        let current = snapshot.currentBreak(at: now)
        let earlier = TimeInterval(snapshot.dto.accumulatedBreakSeconds ?? 0)
        let breakStart = max(shiftStart, now.addingTimeInterval(-current))
        var segments = centered(pause: earlier, from: shiftStart, to: breakStart)
        if current > 0 {
            segments.append(Segment(kind: .pause, start: breakStart, end: now))
        }
        return Block(start: shiftStart, end: now, segments: segments)
    }

    /// Work with `pause` in the middle; the pause is clamped to the span.
    private static func centered(pause: TimeInterval, from start: Date, to end: Date) -> [Segment] {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let pause = min(max(0, pause), span)
        guard pause > 0 else { return [Segment(kind: .work, start: start, end: end)] }
        let pauseStart = start.addingTimeInterval((span - pause) / 2)
        let pauseEnd = pauseStart.addingTimeInterval(pause)
        return [
            Segment(kind: .work, start: start, end: pauseStart),
            Segment(kind: .pause, start: pauseStart, end: pauseEnd),
            Segment(kind: .work, start: pauseEnd, end: end),
        ].filter { $0.end > $0.start }
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `HH:mm` on the day of `day`.
    private static func time(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
}
