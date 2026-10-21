import Foundation
import Security
import VoiceCore

/// The tokens of the connected tools, in the user's keychain, one item per tool (by its id): never in the settings, a
/// log or a command.
public enum ConnectedToolsKeychain {
    private static let service = "\(AppIdentity.name) connected tools"

    public static func token(for tool: UUID) -> String? {
        var query = base(tool)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether there is one, without reading it.
    public static func hasToken(for tool: UUID) -> Bool {
        var query = base(tool)
        query[kSecReturnAttributes] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces the token; nil or empty removes it. Returns false when the keychain refused it.
    @discardableResult
    public static func setToken(_ token: String?, for tool: UUID, name: String = "") -> Bool {
        SecItemDelete(base(tool) as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return true }
        var item = base(tool)
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrLabel] = "\(AppIdentity.name) — " + (name.isEmpty ? "connected tool" : name)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ tool: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: tool.uuidString]
    }
}
