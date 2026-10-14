import Foundation
import Synchronization
@testable import TimebutlerToolbar

enum Fixtures {
    static let running = #"{"status":"running","startTimestamp":1791911608634,"workTimeElapsedSeconds":60,"breakElapsedSeconds":0,"accumulatedBreakSeconds":0,"isBusinessTripActive":false,"startOnlyOnTerminal":false,"pauseOnlyOnTerminal":false,"stopOnlyOnTerminal":false}"#
    static let paused = #"{"status":"paused","startTimestamp":1791911608634,"pauseTimestamp":1791911719831,"workTimeElapsedSeconds":111,"breakElapsedSeconds":11,"accumulatedBreakSeconds":0,"isBusinessTripActive":false,"startOnlyOnTerminal":false,"pauseOnlyOnTerminal":false,"stopOnlyOnTerminal":false}"#
    static let resumed = #"{"status":"running","startTimestamp":1791911608634,"workTimeElapsedSeconds":149,"breakElapsedSeconds":44,"accumulatedBreakSeconds":44,"isBusinessTripActive":false,"startOnlyOnTerminal":false,"pauseOnlyOnTerminal":false,"stopOnlyOnTerminal":false}"#
    static let summary = #"{"commitmentMinutes":420,"workedMinutes":467,"remainingMinutes":0,"percentDone":100,"breakMinutes":90}"#
    static let profile = #"{"id":"502572","name":"Max Mustermann","email":"max@example.com","role":"USER","department":"Entwicklung","avatar":"/images/avatar/x.jpg","isBusinessTripEnabled":false,"isTimeTrackingEnabled":true}"#
    static let idle = #"{"status":"idle"}"#

    static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

/// Builds a DTO for the given situation.
func makeDTO(
    _ status: ClockStatus, work: Int = 0, breakElapsed: Int = 0, accumulated: Int = 0,
    start: Int64? = 1_000_000, pause: Int64? = nil, wait: Int? = nil
) -> TimeClockStatusDto {
    TimeClockStatusDto(
        status: status, startTimestamp: start, pauseTimestamp: pause,
        workTimeElapsedSeconds: work, breakElapsedSeconds: breakElapsed,
        accumulatedBreakSeconds: accumulated, waitSeconds: wait
    )
}

let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

func makeSnapshot(_ dto: TimeClockStatusDto, fetchedAt: Date = referenceDate) -> ShiftSnapshot {
    ShiftSnapshot(dto: dto, fetchedAt: fetchedAt)
}

/// Scriptable API double; records calls. Never touches the network.
final class MockTimeClockAPI: TimeClockAPI, Sendable {
    struct State {
        var status: [Result<TimeClockStatusDto, APIError>] = [.success(makeDTO(.idle))]
        var start: Result<TimeClockStatusDto, APIError> = .success(makeDTO(.running))
        var pause: Result<TimeClockStatusDto, APIError> = .success(makeDTO(.paused))
        var resume: Result<TimeClockStatusDto, APIError> = .success(makeDTO(.running))
        var cancel: Result<TimeClockStatusDto, APIError> = .success(makeDTO(.idle))
        var stop: [Result<StopResult, APIError>] = [.success(.saved(workedMinutes: 60, breakMinutes: 0))]
        var profile: Result<UserProfileResponse, APIError> = .success(UserProfileResponse(name: "Max Mustermann", isTimeTrackingEnabled: true))
        var summary: Result<WorkSummaryResponse, APIError> = .success(WorkSummaryResponse(commitmentMinutes: 420, workedMinutes: 100, breakMinutes: 30))
        var calls: [String] = []
        var statusDelay: Duration?
    }

    let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func status() async throws -> TimeClockStatusDto {
        record("status")
        if let delay = state.withLock({ $0.statusDelay }) { try await Task.sleep(for: delay) }
        return try state.withLock { s in
            let result = s.status.count > 1 ? s.status.removeFirst() : s.status[0]
            return try result.get()
        }
    }
    func start() async throws -> TimeClockStatusDto { record("start"); return try state.withLock { $0.start }.get() }
    func pause() async throws -> TimeClockStatusDto { record("pause"); return try state.withLock { $0.pause }.get() }
    func resume() async throws -> TimeClockStatusDto { record("resume"); return try state.withLock { $0.resume }.get() }
    func cancel() async throws -> TimeClockStatusDto { record("cancel"); return try state.withLock { $0.cancel }.get() }
    func stop(breakRegulation: BreakRegulation?) async throws -> StopResult {
        record("stop:\(breakRegulation?.rawValue ?? "none")")
        return try state.withLock { s in
            let result = s.stop.count > 1 ? s.stop.removeFirst() : s.stop[0]
            return try result.get()
        }
    }
    func profile(token: String?) async throws -> UserProfileResponse {
        record("profile:\(token ?? "stored")")
        return try state.withLock { $0.profile }.get()
    }
    func workSummary() async throws -> WorkSummaryResponse { record("summary"); return try state.withLock { $0.summary }.get() }
}

final class InMemoryTokenStore: TokenStore, Sendable {
    private let token: Mutex<String?>
    init(token: String? = nil) { self.token = Mutex(token) }
    var current: String? { token.withLock { $0 } }
    func readToken() throws -> String? { current }
    func saveToken(_ token: String) throws { self.token.withLock { $0 = token } }
    func deleteToken() throws { token.withLock { $0 = nil } }
}

@MainActor
final class MockScheduler: ReminderScheduler {
    private(set) var applied: [[ScheduledReminder]] = []
    /// Ids the "system" still holds as pending; tests remove entries to simulate delivery.
    var pending: Set<String> = []
    var allowed = true
    func pendingIdentifiers() async -> Set<String> { pending }
    func apply(_ reminders: [ScheduledReminder]) async -> Bool {
        applied.append(reminders)
        pending = Set(reminders.map(\.id))
        return allowed
    }
    func requestAuthorization() async -> Bool { allowed }
}

/// Mutable clock for the store.
@MainActor
final class TestClock {
    var now = referenceDate
}
