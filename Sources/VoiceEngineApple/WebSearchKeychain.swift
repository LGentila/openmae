import Foundation
import Security
import VoiceCore

/// What the web search keeps in the user's keychain, one item per source: the user's Brave Search key, the password of
/// the protection in front of the user's SearXNG. Never in the settings or a log.
public enum WebSearchKeychain {
    private static let service = "\(AppIdentity.name) web search"

    public static func secret(for source: WebSearchSource) -> String? {
        var query = base(source)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether there is one, without reading it.
    public static func hasSecret(for source: WebSearchSource) -> Bool {
        var query = base(source)
        query[kSecReturnAttributes] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces the key or the password; nil or empty removes it. Returns false when the keychain refused it.
    @discardableResult
    public static func setSecret(_ secret: String?, for source: WebSearchSource) -> Bool {
        SecItemDelete(base(source) as CFDictionary)
        guard let secret, !secret.isEmpty else { return true }
        var item = base(source)
        item[kSecValueData] = Data(secret.utf8)
        item[kSecAttrLabel] = "\(AppIdentity.name) — " + (source == .brave ? "Brave Search" : "SearXNG")
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The SearXNG's password keeps the account it had when it was the only one ("searxng").
    private static func base(_ source: WebSearchSource) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: source.rawValue]
    }
}
