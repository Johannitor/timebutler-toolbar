import Foundation
import Synchronization
import Testing
@testable import TimebutlerToolbar

private final class RequestLog: Sendable {
    let requests = Mutex<[URLRequest]>([])
    var last: URLRequest? { requests.withLock { $0.last } }
}

/// Builds a client whose transport returns the scripted response. Never touches the network.
private func makeClient(
    status: Int = 200, body: String = "{}", error: URLError? = nil, token: String? = "tb_secret", log: RequestLog = RequestLog()
) -> TimebutlerClient {
    TimebutlerClient(
        userAgent: "TimebutlerToolbar/9.9",
        tokenProvider: { token },
        transport: { request in
            log.requests.withLock { $0.append(request) }
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    )
}

struct ClientTests {
    @Test func sendsExpectedRequest() async throws {
        let log = RequestLog()
        let client = makeClient(body: Fixtures.running, token: "  tb_secret \n", log: log)
        let dto = try await client.status()
        #expect(dto.status == .running)
        let request = try #require(log.last)
        #expect(request.url?.absoluteString == "https://app.timebutler.com/api/v2/time-clock/status")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tb_secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TimebutlerToolbar/9.9")
    }

    @Test func actionEndpoints() async throws {
        let log = RequestLog()
        let client = makeClient(body: Fixtures.running, log: log)
        _ = try await client.start()
        _ = try await client.pause()
        _ = try await client.resume()
        _ = try await client.cancel()
        let paths = log.requests.withLock { $0.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }
        #expect(paths == [
            "POST /api/v2/time-clock/start", "POST /api/v2/time-clock/pause",
            "POST /api/v2/time-clock/resume", "POST /api/v2/time-clock/cancel",
        ])
        #expect(log.requests.withLock { $0.allSatisfy { $0.httpBody == nil } })
    }

    @Test func profileUsesCandidateToken() async throws {
        let log = RequestLog()
        let client = makeClient(body: Fixtures.profile, token: nil, log: log)
        let profile = try await client.profile(token: " tb_candidate ")
        #expect(profile.name == "Max Mustermann")
        #expect(log.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tb_candidate")
    }

    @Test func missingTokenThrowsWithoutRequest() async {
        let log = RequestLog()
        let client = makeClient(token: nil, log: log)
        await #expect(throws: APIError.noToken) { try await client.status() }
        #expect(log.last == nil)
    }

    @Test(arguments: [
        (401, "{}", APIError.unauthorized),
        (401, "<html><body>Unauthorized</body></html>", .unauthorized),
        (403, "<!DOCTYPE html><html></html>", .unauthorized),
        (403, #"{"error":"terminal"}"#, .terminalOnly),
        (400, "{}", .badRequest(.read)),
        (409, "{}", .conflict(.read)),
        (500, "<html>boom</html>", .server(500)),
        (503, "{}", .server(503)),
        (404, "{}", .http(404)),
    ])
    func statusCodeMapping(status: Int, body: String, expected: APIError) async {
        let client = makeClient(status: status, body: body)
        await #expect(throws: expected) { try await client.status() }
    }

    @Test func conflictIsContextSpecific() async {
        let client = makeClient(status: 409)
        await #expect(throws: APIError.conflict(.start)) { try await client.start() }
        await #expect(throws: APIError.conflict(.pause)) { try await client.pause() }
        await #expect(throws: APIError.conflict(.resume)) { try await client.resume() }
        await #expect(throws: APIError.conflict(.cancel)) { try await client.cancel() }
        await #expect(throws: APIError.conflict(.stop)) { try await client.stop(breakRegulation: nil) }
        #expect(APIError.conflict(.stop).message == "Ausstempeln nicht möglich: Schicht zu kurz (unter 1 Minute) oder bereits beendet.")
    }

    @Test func badRequestIsContextSpecific() async {
        let client = makeClient(status: 400)
        await #expect(throws: APIError.badRequest(.stop)) { try await client.stop(breakRegulation: nil) }
        #expect(APIError.badRequest(.stop).message == "Ausstempeln abgelehnt – evtl. sind Projekt oder Kategorie Pflicht. Bitte in Timebutler ausstempeln.")
        #expect(APIError.badRequest(.start).message == "Zeiterfassung bzw. Stempeluhr ist für dein Konto nicht aktiviert.")
    }

    @Test func transportErrorMapsToNetwork() async {
        let client = makeClient(error: URLError(.notConnectedToInternet))
        await #expect(throws: APIError.network(.notConnectedToInternet)) { try await client.status() }
    }

    @Test func htmlBodyOnSuccessIsDecodingError() async {
        let client = makeClient(status: 200, body: "<html>login</html>")
        await #expect(throws: APIError.decoding) { try await client.status() }
    }

    @Test func germanMessages() {
        #expect(APIError.unauthorized.message == "API-Token ungültig oder widerrufen.")
        #expect(APIError.server(502).message == "Timebutler-Server-Fehler (502). Bitte später erneut versuchen.")
        #expect(APIError.network(.timedOut).message == "Keine Verbindung zu Timebutler.")
        #expect(APIError.decoding.message == "Unerwartete Antwort vom Server.")
    }
}

struct StopFlowTests {
    @Test func savedWithoutBody() async throws {
        let log = RequestLog()
        let client = makeClient(body: #"{"outcome":"saved","workedMinutes":452,"breakMinutes":45}"#, log: log)
        let result = try await client.stop(breakRegulation: nil)
        #expect(result == .saved(workedMinutes: 452, breakMinutes: 45))
        #expect(log.last?.httpBody == nil)
        #expect(log.last?.url?.path == "/api/v2/time-clock/stop")
    }

    @Test func confirmationRequiredThenApply() async throws {
        let log = RequestLog()
        let client = makeClient(
            body: #"{"outcome":"confirmationRequired","breakRegulation":{"obligatory":false,"resultingWorkMinutes":400,"resultingBreakMinutes":30,"detailText":"<b>Hinweis</b>"}}"#,
            log: log
        )
        guard case .confirmationRequired(let info) = try await client.stop(breakRegulation: nil) else {
            Issue.record("expected confirmationRequired")
            return
        }
        #expect(info.resultingBreakMinutes == 30)
        #expect(info.obligatory == false)

        _ = try? await client.stop(breakRegulation: .apply)
        let request = try #require(log.last)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(json == ["breakRegulation": "apply"])
    }

    @Test func status204MeansDiscarded() async throws {
        let client = makeClient(status: 204, body: "")
        #expect(try await client.stop(breakRegulation: nil) == .discardedWhileWaiting)
    }

    @Test func unknownOutcomeIsDecodingError() async {
        let client = makeClient(body: #"{"outcome":"mystery"}"#)
        await #expect(throws: APIError.decoding) { try await client.stop(breakRegulation: nil) }
    }
}
