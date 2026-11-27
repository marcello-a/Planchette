import Foundation
import Security

/// A secret the app keeps for the user — the Jira API token — in the login Keychain, never in
/// `state.json` (which is plain text, and often backed up or synced). An isolated instance (a demo,
/// a test) reads and writes none: it must not hand the real token to whatever drives it.
///
/// Read once per launch: every read of an item another build stored asks the user for the
/// login password, and the Jira poll reads every five minutes. The answer is kept in memory
/// (`KeychainCache`); a write updates it.
enum Keychain {
    static let jiraService = "app.planchette.jira"

    private static let cache = KeychainCache(fetch: fetch)

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(service: String, account: String) -> String? {
        guard !SupportPaths.isIsolated, !account.isEmpty else { return nil }
        return cache.read(service: service, account: account)
    }

    /// One read of the Keychain itself — the one that may ask for the password.
    private static func fetch(service: String, account: String) -> KeychainCache.Fetched {
        var search = query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return .value((item as? Data).flatMap { String(data: $0, encoding: .utf8) })
        case errSecItemNotFound:
            return .value(nil)
        case errSecUserCanceled, errSecAuthFailed:
            // The user said Deny: no new question every five minutes. Settings can save the
            // token again, and the next launch asks again.
            return .value(nil)
        default:
            // Locked keychain, no UI, anything else: not an answer, the next read tries again.
            return .retry
        }
    }

    /// Store `secret`, or remove it when it is empty. True when the Keychain took it.
    @discardableResult
    static func write(_ secret: String, service: String, account: String) -> Bool {
        guard !SupportPaths.isIsolated, !account.isEmpty else { return false }
        let base = query(service: service, account: account)
        guard !secret.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            let done = status == errSecSuccess || status == errSecItemNotFound
            if done { cache.store(nil, service: service, account: account) }
            return done
        }
        let data = Data(secret.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess {
            cache.store(secret, service: service, account: account)
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        cache.store(secret, service: service, account: account)
        return true
    }
}

/// What the Keychain answered, per service and account, for the rest of the launch. Thread-safe:
/// the Jira poll reads off the main thread, Settings on it. The lock is held through the fetch,
/// so two reads at the same moment ask the user once, not twice.
final class KeychainCache: @unchecked Sendable {
    enum Fetched: Equatable {
        /// An answer to keep: the secret, or nil for none (not stored, or denied).
        case value(String?)
        /// No answer (keychain locked, an error): keep nothing, ask again next time.
        case retry
    }

    private let lock = NSLock()
    private var known: [String: String?] = [:]
    private let fetch: (_ service: String, _ account: String) -> Fetched

    init(fetch: @escaping (_ service: String, _ account: String) -> Fetched) {
        self.fetch = fetch
    }

    private static func key(_ service: String, _ account: String) -> String { service + "\n" + account }

    func read(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(service, account)
        if let hit = known[key] { return hit }
        switch fetch(service, account) {
        case .value(let secret):
            known[key] = .some(secret)
            return secret
        case .retry:
            return nil
        }
    }

    func store(_ secret: String?, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        known[Self.key(service, account)] = .some(secret)
    }
}
