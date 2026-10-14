import Synchronization

/// In-memory copy of the token, shared between the store and the API client.
/// Keeps the Keychain from being read on every request.
final class TokenCache: Sendable {
    private let storage = Mutex<String?>(nil)

    var token: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
