import Foundation
import UserNotifications

/// Wires the production dependencies. Under test, inert stand-ins are used so that the hosted test run
/// never reads the Keychain or talks to the network.
@MainActor
enum AppEnvironment {
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static let notificationPresenter = NotificationPresenter()

    static func makeStore() -> ShiftStore {
        if isRunningTests {
            return ShiftStore(
                api: InertAPI(), tokenStore: InertTokenStore(),
                defaults: UserDefaults(suiteName: "de.lochimbaum.TimebutlerToolbar.hosted-tests") ?? .standard
            )
        }
        UNUserNotificationCenter.current().delegate = notificationPresenter
        let cache = TokenCache()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let client = TimebutlerClient(
            userAgent: "TimebutlerToolbar/\(version)",
            tokenProvider: { cache.token }
        )
        return ShiftStore(
            api: client, tokenStore: KeychainStore(), tokenCache: cache,
            scheduler: UserNotificationScheduler()
        )
    }
}

private struct InertTokenStore: TokenStore {
    func readToken() throws -> String? { nil }
    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
}

private struct InertAPI: TimeClockAPI {
    func status() async throws -> TimeClockStatusDto { throw APIError.noToken }
    func start() async throws -> TimeClockStatusDto { throw APIError.noToken }
    func pause() async throws -> TimeClockStatusDto { throw APIError.noToken }
    func resume() async throws -> TimeClockStatusDto { throw APIError.noToken }
    func stop(breakRegulation: BreakRegulation?) async throws -> StopResult { throw APIError.noToken }
    func cancel() async throws -> TimeClockStatusDto { throw APIError.noToken }
    func profile(token: String?) async throws -> UserProfileResponse { throw APIError.noToken }
    func workSummary() async throws -> WorkSummaryResponse { throw APIError.noToken }
}
