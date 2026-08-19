import Foundation
import Security

/// Minimal generic-password Keychain wrapper — the first Keychain use in the app, kept
/// deliberately small. One fixed service; `account` is the provider id ("anthropic", …).
/// Single-machine storage only (no iCloud sync, no access groups), matching the v1
/// no-multi-user-collaboration non-goal.
enum KeychainStore {
    private static let service = "com.shahi.side.provider-credential"

    @discardableResult
    static func set(secret: String, account: String) -> Bool {
        // Generic-password items have no upsert — delete-then-add is the standard idiom.
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func hasSecret(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }
}
