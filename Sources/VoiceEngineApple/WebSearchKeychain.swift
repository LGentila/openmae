import Foundation
import Security
import VoiceCore

/// The password of the protection in front of the user's SearXNG, in the user's keychain. Never in the settings or a
/// log.
public enum WebSearchKeychain {
    private static let service = "\(AppIdentity.name) web search"
    private static let account = "searxng"

    public static func password() -> String? {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether there is one, without reading it.
    public static var hasPassword: Bool {
        var query = base
        query[kSecReturnAttributes] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces the password; nil or empty removes it. Returns false when the keychain refused it.
    @discardableResult
    public static func setPassword(_ password: String?) -> Bool {
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return true }
        var item = base
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrLabel] = "\(AppIdentity.name) — SearXNG"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static var base: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
