import Foundation

/// State of the time clock. Unknown server values decode to `.unknown`.
enum ClockStatus: String, Sendable, Equatable, Decodable {
    case idle, running, paused, waiting, unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClockStatus(rawValue: raw) ?? .unknown
    }
}

/// `TimeClockStatusDto`. The server omits null fields, so everything but `status` is optional.
struct TimeClockStatusDto: Sendable, Equatable {
    var status: ClockStatus
    /// Unix epoch milliseconds.
    var startTimestamp: Int64?
    var pauseTimestamp: Int64?
    var workTimeElapsedSeconds: Int?
    var breakElapsedSeconds: Int?
    var accumulatedBreakSeconds: Int?
    var waitSeconds: Int?
    var isBusinessTripActive: Bool?
    var startOnlyOnTerminal: Bool?
    var pauseOnlyOnTerminal: Bool?
    var stopOnlyOnTerminal: Bool?
}

extension TimeClockStatusDto: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, startTimestamp, pauseTimestamp, workTimeElapsedSeconds, breakElapsedSeconds
        case accumulatedBreakSeconds, waitSeconds, isBusinessTripActive
        case startOnlyOnTerminal, pauseOnlyOnTerminal, stopOnlyOnTerminal
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(ClockStatus.self, forKey: .status) ?? .unknown
        startTimestamp = try c.decodeIfPresent(Int64.self, forKey: .startTimestamp)
        pauseTimestamp = try c.decodeIfPresent(Int64.self, forKey: .pauseTimestamp)
        workTimeElapsedSeconds = try c.decodeIfPresent(Int.self, forKey: .workTimeElapsedSeconds)
        breakElapsedSeconds = try c.decodeIfPresent(Int.self, forKey: .breakElapsedSeconds)
        accumulatedBreakSeconds = try c.decodeIfPresent(Int.self, forKey: .accumulatedBreakSeconds)
        waitSeconds = try c.decodeIfPresent(Int.self, forKey: .waitSeconds)
        isBusinessTripActive = try c.decodeIfPresent(Bool.self, forKey: .isBusinessTripActive)
        startOnlyOnTerminal = try c.decodeIfPresent(Bool.self, forKey: .startOnlyOnTerminal)
        pauseOnlyOnTerminal = try c.decodeIfPresent(Bool.self, forKey: .pauseOnlyOnTerminal)
        stopOnlyOnTerminal = try c.decodeIfPresent(Bool.self, forKey: .stopOnlyOnTerminal)
    }
}

struct UserProfileResponse: Sendable, Equatable, Decodable {
    var id: String?
    var name: String?
    var email: String?
    var role: String?
    var department: String?
    var isBusinessTripEnabled: Bool?
    var isTimeTrackingEnabled: Bool?
}

struct WorkSummaryResponse: Sendable, Equatable, Decodable {
    var commitmentMinutes: Int?
    var workedMinutes: Int?
    var remainingMinutes: Int?
    var percentDone: Double?
    var breakMinutes: Int?
}

enum StopOutcome: String, Sendable, Equatable, Decodable {
    case saved, confirmationRequired, unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopOutcome(rawValue: raw) ?? .unknown
    }
}

struct BreakRegulationInfo: Sendable, Equatable, Decodable {
    var hasNoRemedy: Bool?
    var obligatory: Bool?
    var correctionWorkMinutes: Int?
    var correctionBreakMinutes: Int?
    var resultingWorkMinutes: Int?
    var resultingBreakMinutes: Int?
    var detailText: String?
}

struct TimeClockStopResponse: Sendable, Equatable, Decodable {
    var outcome: StopOutcome
    var id: String?
    var workedMinutes: Int?
    var breakMinutes: Int?
    var breakRegulationApplied: Bool?
    var breakRegulationIgnored: Bool?
    var breakRegulation: BreakRegulationInfo?
}

/// Body value for the second `stop` call.
enum BreakRegulation: String, Sendable, Equatable {
    case apply, ignore
}

/// Result of a `stop` call, already interpreted.
enum StopResult: Sendable, Equatable {
    case saved(workedMinutes: Int?, breakMinutes: Int?)
    case confirmationRequired(BreakRegulationInfo)
    case discardedWhileWaiting
}
