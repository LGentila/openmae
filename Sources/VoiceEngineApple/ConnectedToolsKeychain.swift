import Foundation
import Security
import Synchronization
import VoiceCore

/// The tokens of the connected tools, in the user's keychain, one item per tool (by its id): never in the settings, a
/// log or a command. A tool signed in to with the user's account keeps its credentials there too, as JSON
/// (`MCPCredentials`: the access and refresh tokens, and what refreshing them needs).
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
        item[kSecAttrLabel] = label(name)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Signed in with an account

    /// The credentials of a tool signed in to with the user's account; nil for a pasted token or none.
    public static func credentials(for tool: UUID) -> MCPCredentials? {
        guard let text = token(for: tool), text.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(MCPCredentials.self, from: Data(text.utf8))
    }

    /// Replaces the credentials (nil removes them), keeping the item's name when `name` is nil (a refresh). Returns
    /// false when the keychain refused them.
    @discardableResult
    public static func setCredentials(_ credentials: MCPCredentials?, for tool: UUID, name: String? = nil) -> Bool {
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return setToken(nil, for: tool) }
        var changes: [CFString: Any] = [kSecValueData: data]
        if let name { changes[kSecAttrLabel] = label(name) }
        let status = SecItemUpdate(base(tool) as CFDictionary, changes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var item = base(tool)
        item[kSecValueData] = data
        item[kSecAttrLabel] = label(name ?? "")
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The account of a tool, the same for all its clients: one refresh at a time (see `MCPAccountAccess`).
    public static func account(for tool: UUID) -> MCPAccountAccess {
        accounts.withLock { accounts in
            if let account = accounts[tool] { return account }
            let account = MCPAccountAccess(load: { credentials(for: tool) },
                                           save: { setCredentials($0, for: tool) })
            accounts[tool] = account
            return account
        }
    }

    /// The tool was removed, or its trial is over: its account is let go (its credentials are not touched).
    public static func forgetAccount(_ tool: UUID) {
        _ = accounts.withLock { $0.removeValue(forKey: tool) }
    }

    private static let accounts = Mutex<[UUID: MCPAccountAccess]>([:])

    private static func label(_ name: String) -> String {
        "\(AppIdentity.name) — " + (name.isEmpty ? "connected tool" : name)
    }

    private static func base(_ tool: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: tool.uuidString]
    }
}
