import Foundation
import UserNotifications

struct ScheduledReminder: Sendable, Equatable {
    /// Notification request identifier, unique per shift and threshold (`break-6h-<startTimestamp>`).
    let id: String
    let fireIn: TimeInterval
    let title: String
    let body: String
}

/// ArbZG §4 break reminder rules and the pure scheduling math.
enum BreakReminder {
    struct Rule: Sendable {
        let id: String
        let thresholdHours: Int
        let requiredBreakMinutes: Int
        var threshold: TimeInterval { TimeInterval(thresholdHours * 3600) }
        var requiredBreak: TimeInterval { TimeInterval(requiredBreakMinutes * 60) }
    }

    static let rules = [
        Rule(id: "break-6h", thresholdHours: 6, requiredBreakMinutes: 30),
        Rule(id: "break-9h", thresholdHours: 9, requiredBreakMinutes: 45),
    ]
    static let leadTime: TimeInterval = 15 * 60

    static let identifierPrefix = "break-"
    /// Prefix for the "break ended automatically" notice; deliberately outside the planned prefixes,
    /// so replacing the planned reminders never removes it.
    static let autoBreakEndedPrefix = "autobreak-ended-"

    /// Prefixes of all reminders managed through `ReminderScheduler.apply` (break and shift end reminders).
    static let plannedPrefixes = [identifierPrefix, ShiftEndReminder.identifierPrefix]

    static func isPlanned(_ id: String) -> Bool {
        plannedPrefixes.contains { id.hasPrefix($0) }
    }

    static func requestID(startTimestamp: Int64, rule: Rule) -> String {
        "\(rule.id)-\(startTimestamp)"
    }

    /// Which previously scheduled reminders were really delivered. `ledger` maps request id to its
    /// planned fire date. A reminder counts as delivered once its fire date has passed and the system
    /// no longer holds it as pending (e.g. a Mac that slept over the fire time still has it pending).
    static func deliveredIDs(ledger: [String: Date], pending: Set<String>, now: Date) -> Set<String> {
        Set(ledger.filter { $0.value <= now && !pending.contains($0.key) }.keys)
    }

    /// Reminders to schedule for the given snapshot.
    /// - Parameter delivered: request ids already delivered (only consulted once the lead point has passed).
    static func plan(
        snapshot: ShiftSnapshot?, now: Date, enabled: Bool, delivered: Set<String>
    ) -> [ScheduledReminder] {
        guard enabled, let snapshot, snapshot.status == .running else { return [] }
        let net = snapshot.netWork(at: now)
        let totalBreak = snapshot.totalBreak(at: now)
        let start = snapshot.dto.startTimestamp ?? 0

        return rules.compactMap { rule in
            guard totalBreak < rule.requiredBreak, net < rule.threshold else { return nil }
            let key = requestID(startTimestamp: start, rule: rule)
            let leadPoint = rule.threshold - leadTime
            var fireIn = leadPoint - net
            if fireIn <= 0 {
                // Lead point already passed: remind right away, unless that was done for this shift.
                guard !delivered.contains(key) else { return nil }
                fireIn = 1
            }
            let minutesLeft = max(1, Int(((rule.threshold - net - fireIn) / 60).rounded(.up)))
            let captured = Int(totalBreak / 60)
            return ScheduledReminder(
                id: key,
                fireIn: fireIn,
                title: "Pause nicht vergessen",
                body: "In \(minutesLeft) \(minutesLeft == 1 ? "Minute" : "Minuten") erreichst du \(rule.thresholdHours) Stunden Arbeitszeit. Bisher erfasst: \(captured) Min. Pause – nötig sind \(rule.requiredBreakMinutes) Min."
            )
        }
    }
}

/// Shift end reminders: daily target reached, and the ArbZG §3 maximum of 10 hours approaching.
/// Both count today's saved work (work summary) plus the running shift.
enum ShiftEndReminder {
    static let identifierPrefix = "shift-"
    static let maxWorkHours = 10
    static var maxWork: TimeInterval { TimeInterval(maxWorkHours * 3600) }

    static func plan(
        snapshot: ShiftSnapshot?, summary: WorkSummaryResponse?, now: Date,
        targetEnabled: Bool, maxEnabled: Bool, delivered: Set<String>
    ) -> [ScheduledReminder] {
        guard let snapshot, snapshot.status == .running else { return [] }
        let start = snapshot.dto.startTimestamp ?? 0
        let saved = TimeInterval((summary?.workedMinutes ?? 0) * 60)
        let worked = saved + snapshot.netWork(at: now)
        var reminders: [ScheduledReminder] = []

        // Target: only if it is not already met by saved entries before this shift.
        if targetEnabled, let minutes = summary?.commitmentMinutes, minutes > 0, saved < TimeInterval(minutes * 60) {
            let target = TimeInterval(minutes * 60)
            let key = "\(identifierPrefix)target-\(start)"
            if let fireIn = fireIn(target - worked, key: key, delivered: delivered) {
                reminders.append(ScheduledReminder(
                    id: key,
                    fireIn: fireIn,
                    title: "Sollzeit erreicht",
                    body: "Du hast dein Soll von \(DurationFormatting.hmm(target)) h für heute erreicht und kannst ausstempeln."
                ))
            }
        }

        if maxEnabled, worked < maxWork {
            let key = "\(identifierPrefix)\(maxWorkHours)h-\(start)"
            if let fireIn = fireIn(maxWork - BreakReminder.leadTime - worked, key: key, delivered: delivered) {
                let minutesLeft = max(1, Int(((maxWork - worked - fireIn) / 60).rounded(.up)))
                reminders.append(ScheduledReminder(
                    id: key,
                    fireIn: fireIn,
                    title: "Höchstarbeitszeit bald erreicht",
                    body: "In \(minutesLeft) \(minutesLeft == 1 ? "Minute" : "Minuten") erreichst du \(maxWorkHours) Stunden Arbeitszeit, die gesetzliche Höchstgrenze. Bitte rechtzeitig ausstempeln."
                ))
            }
        }
        return reminders
    }

    /// Fire delay; a passed fire point reminds right away, unless that was already done for this shift.
    private static func fireIn(_ delay: TimeInterval, key: String, delivered: Set<String>) -> TimeInterval? {
        if delay > 0 { return delay }
        return delivered.contains(key) ? nil : 1
    }
}

/// Schedules the planned reminders with the system.
@MainActor
protocol ReminderScheduler: AnyObject {
    /// Identifiers of planned (break and shift end) reminders the system still holds as pending.
    func pendingIdentifiers() async -> Set<String>
    /// Replaces all pending planned reminders. Returns `false` if notifications are not allowed.
    func apply(_ reminders: [ScheduledReminder]) async -> Bool
    /// Delivers a one-off notification right away (if notifications are allowed).
    func notify(_ notice: ScheduledReminder) async
    func requestAuthorization() async -> Bool
}

@MainActor
final class UserNotificationScheduler: ReminderScheduler {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingIdentifiers() async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter(BreakReminder.isPlanned))
    }

    func apply(_ reminders: [ScheduledReminder]) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let stale = await pendingIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        guard !reminders.isEmpty else { return true }

        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = await requestAuthorization()
            settings = await center.notificationSettings()
        }
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return false }

        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireIn), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
        return true
    }

    func notify(_ notice: ScheduledReminder) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        // A nil trigger delivers immediately.
        try? await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }
}

/// Lets reminders appear as banners even though this app counts as frontmost-capable.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
