import Foundation

enum DurationFormatting {
    /// `3:42` (floor rounding, hours uncapped).
    static func hmm(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        return String(format: "%d:%02d", total / 3600, total % 3600 / 60)
    }

    /// `3:42:07`
    static func hmmss(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    /// `7:32` from minutes.
    static func minutesHmm(_ minutes: Int) -> String {
        hmm(TimeInterval(max(0, minutes) * 60))
    }

    /// `M:SS`, used for the running break.
    static func mss(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Clock time `HH:mm` in the user's locale and time zone.
    static func clockTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func clockTimeWithSeconds(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// Spoken form for accessibility, e.g. "3 Stunden 42 Minuten".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        return "\(hours) \(hours == 1 ? "Stunde" : "Stunden") \(minutes) \(minutes == 1 ? "Minute" : "Minuten")"
    }

    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
    }
}
