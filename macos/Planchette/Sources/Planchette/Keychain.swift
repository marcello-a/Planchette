import Foundation
import Security

/// A secret the app keeps for the user — the Jira API token — in the login Keychain, never in
/// `state.json` (which is plain text, and often backed up or synced). An isolated instance (a demo,
/// a test) reads and writes none: it must not hand the real token to whatever drives it.
enum Keychain {
    static let jiraService = "app.planchette.jira"

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(service: String, account: String) -> String? {
        guard !SupportPaths.isIsolated, !account.isEmpty else { return nil }
        var search = query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store `secret`, or remove it when it is empty. True when the Keychain took it.
    @discardableResult
    static func write(_ secret: String, service: String, account: String) -> Bool {
        guard !SupportPaths.isIsolated, !account.isEmpty else { return false }
        let base = query(service: service, account: account)
        guard !secret.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(secret.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
