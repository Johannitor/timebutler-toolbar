import Foundation
import OSLog

/// Everything the app needs from the Timebutler time clock API.
protocol TimeClockAPI: Sendable {
    func status() async throws -> TimeClockStatusDto
    func start() async throws -> TimeClockStatusDto
    func pause() async throws -> TimeClockStatusDto
    func resume() async throws -> TimeClockStatusDto
    func stop(breakRegulation: BreakRegulation?) async throws -> StopResult
    func cancel() async throws -> TimeClockStatusDto
    /// Fetches the profile. `token` overrides the stored token (used to validate a candidate token).
    func profile(token: String?) async throws -> UserProfileResponse
    func workSummary() async throws -> WorkSummaryResponse
    /// Saved time entries of the current month.
    func timeEntries() async throws -> [TimeEntryDto]
}

/// Performs a request. Abstracted so tests never touch the network.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

struct TimebutlerClient: TimeClockAPI {
    static let baseURL = URL(string: "https://app.timebutler.com/api/v2")!
    private static let logger = Logger(subsystem: "de.lochimbaum.TimebutlerToolbar", category: "API")

    private let baseURL: URL
    private let tokenProvider: @Sendable () -> String?
    private let transport: HTTPTransport
    private let userAgent: String

    init(
        baseURL: URL = TimebutlerClient.baseURL,
        userAgent: String = "TimebutlerToolbar/1.0",
        tokenProvider: @escaping @Sendable () -> String?,
        transport: @escaping HTTPTransport = TimebutlerClient.urlSessionTransport()
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    /// Transport backed by an ephemeral `URLSession` with a 15 s timeout.
    static func urlSessionTransport() -> HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    // MARK: TimeClockAPI

    func status() async throws -> TimeClockStatusDto {
        try await decoded(.get, "time-clock/status", context: .read)
    }

    func start() async throws -> TimeClockStatusDto {
        try await decoded(.post, "time-clock/start", context: .start)
    }

    func pause() async throws -> TimeClockStatusDto {
        try await decoded(.post, "time-clock/pause", context: .pause)
    }

    func resume() async throws -> TimeClockStatusDto {
        try await decoded(.post, "time-clock/resume", context: .resume)
    }

    func cancel() async throws -> TimeClockStatusDto {
        try await decoded(.post, "time-clock/cancel", context: .cancel)
    }

    func profile(token: String?) async throws -> UserProfileResponse {
        try await decoded(.get, "user/profile", context: .read, token: token)
    }

    func workSummary() async throws -> WorkSummaryResponse {
        try await decoded(.get, "time-tracking/work-summary", context: .read)
    }

    func timeEntries() async throws -> [TimeEntryDto] {
        try await decoded(.get, "time-entries/my", context: .read)
    }

    func stop(breakRegulation: BreakRegulation?) async throws -> StopResult {
        let body = try breakRegulation.map { try JSONSerialization.data(withJSONObject: ["breakRegulation": $0.rawValue]) }
        let (status, data) = try await send(.post, "time-clock/stop", body: body, context: .stop, token: nil)
        if status == 204 { return .discardedWhileWaiting }
        let response: TimeClockStopResponse = try decode(data)
        switch response.outcome {
        case .saved:
            return .saved(workedMinutes: response.workedMinutes, breakMinutes: response.breakMinutes)
        case .confirmationRequired:
            guard let info = response.breakRegulation else { throw APIError.decoding }
            return .confirmationRequired(info)
        case .unknown:
            throw APIError.decoding
        }
    }

    // MARK: Plumbing

    private enum Method: String { case get = "GET", post = "POST" }

    private func decoded<T: Decodable>(
        _ method: Method, _ path: String, context: APIError.Context, token: String? = nil
    ) async throws -> T {
        let (_, data) = try await send(method, path, body: nil, context: context, token: token)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func send(
        _ method: Method, _ path: String, body: Data?, context: APIError.Context, token: String?
    ) async throws -> (status: Int, data: Data) {
        let rawToken = token ?? tokenProvider()
        guard let bearer = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines), !bearer.isEmpty else {
            throw APIError.noToken
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let started = ContinuousClock.now
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            Self.logger.info("\(method.rawValue, privacy: .public) \(path, privacy: .public) failed: \(error.code.rawValue)")
            throw APIError.network(error.code)
        }
        // Log only method, path, status and duration; never headers or the token.
        Self.logger.info("\(method.rawValue, privacy: .public) \(path, privacy: .public) -> \(response.statusCode) in \(started.duration(to: .now).description, privacy: .public)")

        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(statusCode: response.statusCode, body: data, context: context)
        }
        return (response.statusCode, data)
    }
}
