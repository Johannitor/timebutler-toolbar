import Foundation

/// Errors surfaced to the user. Messages are German (informal "du").
enum APIError: Error, Sendable, Equatable {
    /// The request that was in flight; selects the wording of a 409 conflict.
    enum Context: Sendable, Equatable {
        case read, start, pause, resume, stop, cancel
    }

    case noToken
    case unauthorized
    case terminalOnly
    case conflict(Context)
    case badRequest(Context)
    case server(Int)
    case network(URLError.Code)
    case decoding
    case http(Int)
    case keychain(String)

    var message: String {
        switch self {
        case .noToken: "Kein API-Token hinterlegt."
        case .unauthorized: "API-Token ungültig oder widerrufen."
        case .terminalOnly: "Diese Aktion ist nur am Zeiterfassungsterminal erlaubt."
        case .conflict(let context): Self.conflictMessage(context)
        case .badRequest(let context): Self.badRequestMessage(context)
        case .server(let code): "Timebutler-Server-Fehler (\(code)). Bitte später erneut versuchen."
        case .network: "Keine Verbindung zu Timebutler."
        case .decoding: "Unerwartete Antwort vom Server."
        case .http(let code): "Unerwartete Antwort vom Server (HTTP \(code))."
        case .keychain(let detail): "Schlüsselbund-Fehler: \(detail)"
        }
    }

    /// Errors that say nothing about the shift state and are worth retrying in the background.
    var isConnectivityRelated: Bool {
        switch self {
        case .network, .server, .decoding, .http: true
        default: false
        }
    }

    private static func badRequestMessage(_ context: Context) -> String {
        context == .stop
            ? "Ausstempeln abgelehnt – evtl. sind Projekt oder Kategorie Pflicht. Bitte in Timebutler ausstempeln."
            : "Zeiterfassung bzw. Stempeluhr ist für dein Konto nicht aktiviert."
    }

    private static func conflictMessage(_ context: Context) -> String {
        switch context {
        case .start: "Die Stempeluhr läuft bereits."
        case .pause: "Die Stempeluhr läuft nicht oder ist bereits pausiert."
        case .resume: "Die Stempeluhr ist nicht pausiert."
        case .stop: "Ausstempeln nicht möglich: Schicht zu kurz (unter 1 Minute) oder bereits beendet."
        case .cancel: "Es gibt keine laufende Schicht, die verworfen werden könnte."
        case .read: "Die Anfrage steht im Konflikt mit dem aktuellen Zustand."
        }
    }

    /// Maps a non-2xx response to an error. Pure, so it can be unit-tested.
    static func from(statusCode: Int, body: Data, context: Context) -> APIError {
        if statusCode == 401 { return .unauthorized }
        // An invalid or malformed token may yield an HTML error page instead of JSON.
        if (400..<500).contains(statusCode), looksLikeHTML(body) { return .unauthorized }
        switch statusCode {
        case 400: return .badRequest(context)
        case 403: return .terminalOnly
        case 409: return .conflict(context)
        case 500..<600: return .server(statusCode)
        default: return .http(statusCode)
        }
    }

    static func looksLikeHTML(_ body: Data) -> Bool {
        let prefix = String(decoding: body.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // JSON never starts with "<", so any markup-looking body counts as an HTML error page.
        return prefix.hasPrefix("<")
    }
}
