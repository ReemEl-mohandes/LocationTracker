import Foundation
import Security

/// The three values the server hands out as cookies at login.
struct SessionTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var csrfToken: String
}

/// Keeps the session in the Keychain. "After first unlock" rather than "when unlocked":
/// uploads keep running in the background while the phone is locked in a pocket, and they
/// need to read the token then.
enum TokenStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "LocationTrackerClient.session",
        kSecAttrAccount as String: "tokens",
    ]

    private static let lock = NSLock()

    static func load() -> SessionTokens? {
        lock.lock(); defer { lock.unlock() }

        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SessionTokens.self, from: data)
    }

    static func save(_ tokens: SessionTokens) {
        lock.lock(); defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(base as CFDictionary)
    }
}
