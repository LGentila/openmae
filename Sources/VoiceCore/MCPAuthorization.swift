import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto: the same API on Linux and Windows
#endif

// Signing in to a connected tool with the user's account, as MCP's authorization has it (OAuth 2.1 with PKCE): the
// service says where its authorization server is (its protected resource metadata, RFC 9728, named by the 401's
// `WWW-Authenticate` or found at `/.well-known/oauth-protected-resource`), that server describes itself (RFC 8414, or
// OpenID Connect's discovery), the app registers itself when the server lets apps do so (RFC 7591), and the user signs
// in in the browser (`MCPAccountSignIn`). Without protected resource metadata (MCP 2025-03-26), the service's own
// origin is asked for the authorization server's metadata; a service that describes neither does not offer signing in
// (its default endpoints are not guessed: the browser would show the user an error page).
//
// Home Assistant (2026) gives both metadata, takes PKCE, and registers no client: its clients are URLs (IndieAuth),
// and the address the browser comes back to must share the client's scheme and host. The browser comes back to this
// Mac at a loopback address (RFC 8252), which also names the app: no web page of ours is needed.
//
// The tokens are kept by the app in the keychain (`ConnectedToolsKeychain`), never in the settings, a log or a command.

/// Why signing in with an account did not work.
public enum MCPSignInError: Error, Sendable, Equatable {
    /// The service does not say where to sign in (no authorization server), or not in a way this app can use.
    case notOffered
    /// Nothing answers at the address, or at its authorization server's.
    case unreachable
    /// The browser's window was closed before the end.
    case cancelled
    /// The service, or the user on its page, refused: its words.
    case refused(String)
}

/// What signing in gave, for the requests and to refresh it. Kept in the keychain only.
public struct MCPCredentials: Sendable, Codable, Equatable, CustomStringConvertible {
    public var accessToken: String
    public var refreshToken: String?
    /// When the access token expires; nil when the service did not say.
    public var expiresAt: Date?
    /// When it is refreshed before a request: a minute before it expires, or halfway through a shorter life.
    public var refreshAt: Date?
    public var tokenEndpoint: URL
    /// Where the tokens are revoked when the tool is removed (RFC 7009); nil when the service has no such address.
    public var revocationEndpoint: URL?
    /// The app's name at the service: the one it registered, or the loopback address it signed in from.
    public var clientID: String
    /// A secret the service gave at the registration (most give none to an app on a Mac).
    public var clientSecret: String?
    /// The secret goes in an `Authorization: Basic` header (`client_secret_basic`), not in the form.
    public var secretInHeader: Bool
    /// The service's address as sent with every request for tokens (RFC 8707's `resource`).
    public var resource: String?
    public var scope: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, refreshAt: Date? = nil,
                tokenEndpoint: URL, revocationEndpoint: URL? = nil, clientID: String, clientSecret: String? = nil,
                secretInHeader: Bool = false, resource: String? = nil, scope: String? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshAt = refreshAt
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.secretInHeader = secretInHeader
        self.resource = resource
        self.scope = scope
    }

    /// Never the tokens nor the secret.
    public var description: String {
        "MCPCredentials(client: \(clientID), expires: \(expiresAt.map { "\($0)" } ?? "not said"), "
            + "refresh token: \(refreshToken == nil ? "no" : "yes"))"
    }

    /// The access token is to be refreshed before the next request.
    public func isDue(at now: Date = Date()) -> Bool {
        refreshToken != nil && refreshAt.map { $0 <= now } ?? false
    }
}

/// An authorization server, as its metadata describes it.
public struct MCPAuthorizationServer: Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    /// Where apps register themselves (RFC 7591); nil: the server registers none (Home Assistant).
    public var registrationEndpoint: URL?
    public var revocationEndpoint: URL?

    public init(authorizationEndpoint: URL, tokenEndpoint: URL, registrationEndpoint: URL? = nil,
                revocationEndpoint: URL? = nil)
    {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
    }
}

/// Where and how to sign in to a service, as discovered.
public struct MCPAuthorizationPlan: Sendable, Equatable {
    public var server: MCPAuthorizationServer
    /// The service's address as its protected resource metadata gives it, or as typed: sent with each request for
    /// tokens (RFC 8707), as MCP asks.
    public var resource: String
    /// What to ask for: the scope the 401 named, or all those the service lists; nil when it says nothing.
    public var scope: String?
}

/// How the app is known to the authorization server.
public struct MCPClientIdentity: Sendable, Equatable {
    public var id: String
    public var secret: String?
    public var secretInHeader: Bool

    public init(id: String, secret: String? = nil, secretInHeader: Bool = false) {
        self.id = id
        self.secret = secret
        self.secretInHeader = secretInHeader
    }
}

/// Proof Key for Code Exchange (RFC 7636): a random verifier kept by the app, and its SHA-256 sent with the page.
public struct MCPPKCE: Sendable, Equatable {
    public static let method = "S256"
    public let verifier: String

    /// A new verifier: 32 random bytes, 43 characters.
    public init() {
        var generator = SystemRandomNumberGenerator()
        verifier = MCPAuthorization.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    public init(verifier: String) {
        self.verifier = verifier
    }

    public var challenge: String {
        MCPAuthorization.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// The steps of signing in that go through the network: discovery, registration, the page's address, the tokens.
public enum MCPAuthorization {
    /// How long one request may take.
    static let timeout: TimeInterval = 15

    // MARK: - Discovery

    /// Where to sign in for the service at `address`: its protected resource metadata at its well-known addresses (RFC
    /// 9728), then its authorization server's (RFC 8414, OpenID Connect). Without the first, the service's origin is its
    /// authorization server (MCP 2025-03-26). Only when neither answers is the service asked without a token, for the
    /// metadata its 401 names: Home Assistant shows its user "Login attempt failed" at each 401.
    public static func discover(_ address: URL, session: URLSession) async throws -> MCPAuthorizationPlan {
        var reached = false
        var found: ResourceMetadata?
        for url in wellKnown("oauth-protected-resource", for: address) where found == nil {
            guard let (status, json) = await getJSON(url, session: session) else { continue }
            reached = true
            found = resourceMetadata(status, json, address: address)
        }
        if let found {
            let (server, answered) = await authorizationServer(of: found.issuers, session: session)
            if let server {
                return MCPAuthorizationPlan(server: server, resource: found.resource ?? canonical(address), scope: found.scope)
            }
            throw reached || answered ? MCPSignInError.notOffered : MCPSignInError.unreachable
        }
        if let origin = origin(address) {
            let (server, answered) = await authorizationServer(of: [origin], session: session)
            reached = reached || answered
            if let server { return MCPAuthorizationPlan(server: server, resource: canonical(address), scope: nil) }
        }
        let (answered, challenge) = await challenge(address, session: session)
        reached = reached || answered
        let parameters = challenge.map(challengeParameters) ?? [:]
        if let named = parameters["resource_metadata"].flatMap({ URL(string: $0) }), isWeb(named),
           let (status, json) = await getJSON(named, session: session),
           let found = resourceMetadata(status, json, address: address),
           case (let server?, _) = await authorizationServer(of: found.issuers, session: session)
        {
            return MCPAuthorizationPlan(server: server, resource: found.resource ?? canonical(address),
                                        scope: parameters["scope"] ?? found.scope)
        }
        throw reached ? MCPSignInError.notOffered : MCPSignInError.unreachable
    }

    /// What protected resource metadata says: the service's address, its authorization servers, all its scopes.
    struct ResourceMetadata {
        var resource: String?
        var issuers: [URL]
        var scope: String?
    }

    /// Protected resource metadata that names authorization servers, for the service at `address`.
    static func resourceMetadata(_ status: Int, _ json: JSONValue?, address: URL) -> ResourceMetadata? {
        guard status == 200, case .object(let metadata)? = json, case .array(let servers)? = metadata["authorization_servers"]
        else { return nil }
        // Another service's metadata is not this one's (RFC 9728 §3.3). Home Assistant names its origin.
        if let named = metadata["resource"]?.text, let url = URL(string: named), !sameOrigin(url, address) { return nil }
        let issuers = servers.compactMap { $0.text.flatMap { URL(string: $0) } }.filter(isWeb)
        guard !issuers.isEmpty else { return nil }
        var scopes: [String] = []
        if case .array(let listed)? = metadata["scopes_supported"] { scopes = listed.compactMap(\.text) }
        return ResourceMetadata(resource: metadata["resource"]?.text, issuers: issuers,
                                scope: scopes.isEmpty ? nil : scopes.joined(separator: " "))
    }

    /// The first of these authorization servers whose metadata can be used, and whether anything answered.
    static func authorizationServer(of issuers: [URL], session: URLSession) async -> (MCPAuthorizationServer?, Bool) {
        var answered = false
        for issuer in issuers {
            for url in wellKnownServer(issuer) {
                guard let (status, json) = await getJSON(url, session: session) else { continue }
                answered = true
                if status == 200, let json, let server = authorizationServer(json, issuer: issuer) { return (server, true) }
            }
        }
        return (nil, answered)
    }

    /// Asks the service to start a session without a token: whether it answered, and its `WWW-Authenticate` when it
    /// refused.
    static func challenge(_ address: URL, session: URLSession) async -> (answered: Bool, challenge: String?) {
        var request = URLRequest(url: address, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": .string(MCPClient.protocolVersion), "capabilities": [:],
            "clientInfo": ["name": .string(AppIdentity.name), "version": "1"],
        ]]
        request.httpBody = try? JSONEncoder().encode(message)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return (false, nil)
        }
        guard http.statusCode == 401 || http.statusCode == 403 else { return (true, nil) }
        return (true, http.value(forHTTPHeaderField: "WWW-Authenticate"))
    }

    /// The parameters of a `WWW-Authenticate` header: `Bearer resource_metadata="…", scope="a b"` → their values, by
    /// lowercased name.
    public static func challengeParameters(_ header: String) -> [String: String] {
        var parameters: [String: String] = [:]
        var rest = Substring(header)
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " || $0 == "," }
            // A name: a scheme ("Bearer") when no "=" follows it.
            let name = rest.prefix { $0 != "=" && $0 != " " && $0 != "," }
            rest = rest.dropFirst(name.count)
            guard rest.first == "=" else { continue }
            rest = rest.dropFirst()
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                while let character = rest.first {
                    rest = rest.dropFirst()
                    if escaped {
                        value.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        value.append(character)
                    }
                }
            } else {
                value = String(rest.prefix { $0 != "," && $0 != " " })
                rest = rest.dropFirst(value.count)
            }
            if !name.isEmpty { parameters[name.lowercased()] = value }
        }
        return parameters
    }

    /// An authorization server's metadata, its addresses read against its issuer (Home Assistant gives them relative
    /// when it does not know its own URL). Its addresses are https, but on the home network, where Home Assistant
    /// often has no certificate.
    static func authorizationServer(_ json: JSONValue, issuer: URL) -> MCPAuthorizationServer? {
        guard case .object(let metadata) = json else { return nil }
        func endpoint(_ key: String) -> URL? {
            guard let text = metadata[key]?.text, !text.isEmpty,
                  let url = URL(string: text, relativeTo: origin(issuer))?.absoluteURL, isWeb(url),
                  url.scheme?.lowercased() == "https" || MCPClient.isHomeNetwork(url.host() ?? "")
            else { return nil }
            return url
        }
        guard let authorization = endpoint("authorization_endpoint"), let token = endpoint("token_endpoint") else {
            return nil
        }
        // PKCE with S256 is always sent: a server that lists its methods without that one cannot be used.
        if case .array(let methods)? = metadata["code_challenge_methods_supported"],
           !methods.contains(where: { $0.text == MCPPKCE.method })
        {
            return nil
        }
        if case .array(let types)? = metadata["response_types_supported"], !types.contains(where: { $0.text == "code" }) {
            return nil
        }
        return MCPAuthorizationServer(authorizationEndpoint: authorization, tokenEndpoint: token,
                                      registrationEndpoint: endpoint("registration_endpoint"),
                                      revocationEndpoint: endpoint("revocation_endpoint"))
    }

    // MARK: - Registration

    /// Registers the app (RFC 7591), as an app without a secret that comes back to `redirect`.
    public static func register(_ server: MCPAuthorizationServer, redirect: URL, session: URLSession) async throws
        -> MCPClientIdentity
    {
        guard let endpoint = server.registrationEndpoint else { throw MCPSignInError.notOffered }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let body: JSONValue = [
            "client_name": .string(AppIdentity.name), "redirect_uris": [.string(redirect.absoluteString)],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        request.httpBody = try? JSONEncoder().encode(body)
        let (status, json) = try await send(request, session: session)
        guard (200..<300).contains(status), case .object(let client)? = json, let id = client["client_id"]?.text, !id.isEmpty
        else { throw MCPSignInError.refused(refusal(status, json)) }
        let secret = client["client_secret"]?.text.flatMap { $0.isEmpty ? nil : $0 }
        // RFC 7591: without a method named, a secret goes in the header.
        let method = client["token_endpoint_auth_method"]?.text ?? (secret == nil ? "none" : "client_secret_basic")
        return MCPClientIdentity(id: id, secret: secret, secretInHeader: secret != nil && method == "client_secret_basic")
    }

    // MARK: - The page and the tokens

    /// The page where the user signs in.
    public static func authorizationURL(_ plan: MCPAuthorizationPlan, client: String, redirect: URL, pkce: MCPPKCE,
                                        state: String) -> URL
    {
        var items = [("response_type", "code"), ("client_id", client), ("redirect_uri", redirect.absoluteString),
                     ("code_challenge", pkce.challenge), ("code_challenge_method", MCPPKCE.method), ("state", state),
                     ("resource", plan.resource)]
        if let scope = plan.scope, !scope.isEmpty { items.append(("scope", scope)) }
        guard var components = URLComponents(url: plan.server.authorizationEndpoint, resolvingAgainstBaseURL: true) else {
            return plan.server.authorizationEndpoint
        }
        let query = formEncoded(items)
        components.percentEncodedQuery = components.percentEncodedQuery.map { $0.isEmpty ? query : "\($0)&\(query)" }
            ?? query
        return components.url ?? plan.server.authorizationEndpoint
    }

    /// Trades the code the browser brought back for the tokens.
    public static func exchange(code: String, plan: MCPAuthorizationPlan, client: MCPClientIdentity, redirect: URL,
                                pkce: MCPPKCE, session: URLSession, now: Date = Date()) async throws -> MCPCredentials
    {
        let base = MCPCredentials(accessToken: "", tokenEndpoint: plan.server.tokenEndpoint,
                                  revocationEndpoint: plan.server.revocationEndpoint, clientID: client.id,
                                  clientSecret: client.secret, secretInHeader: client.secretInHeader,
                                  resource: plan.resource, scope: plan.scope)
        return try await tokens([("grant_type", "authorization_code"), ("code", code),
                                 ("redirect_uri", redirect.absoluteString), ("code_verifier", pkce.verifier)],
                                base, session: session, now: now)
    }

    /// New tokens for `credentials`, with its refresh token. A service that gives no new refresh token keeps the old
    /// one valid (Home Assistant). Throws `refused` when the service refuses it (signing in again is needed),
    /// `unreachable` when it could not be asked.
    public static func refreshed(_ credentials: MCPCredentials, session: URLSession, now: Date = Date()) async throws
        -> MCPCredentials
    {
        guard let refresh = credentials.refreshToken else { throw MCPSignInError.refused("no refresh token") }
        return try await tokens([("grant_type", "refresh_token"), ("refresh_token", refresh)], credentials,
                                session: session, now: now)
    }

    /// Asks the service to forget the tokens (RFC 7009), when it has an address for it; what it answers does not matter.
    public static func revoke(_ credentials: MCPCredentials, session: URLSession) async {
        guard let endpoint = credentials.revocationEndpoint else { return }
        var form = [("token", credentials.refreshToken ?? credentials.accessToken),
                    ("token_type_hint", credentials.refreshToken == nil ? "access_token" : "refresh_token")]
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        authenticate(&request, &form, credentials)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncoded(form).utf8)
        _ = try? await session.data(for: request)
    }

    /// A request to the token endpoint, as `base`'s client, for `base`'s resource; the new credentials.
    private static func tokens(_ form: [(String, String)], _ base: MCPCredentials, session: URLSession, now: Date)
        async throws -> MCPCredentials
    {
        var form = form + [("client_id", base.clientID)]
        if let resource = base.resource { form.append(("resource", resource)) }
        var request = URLRequest(url: base.tokenEndpoint, timeoutInterval: timeout)
        authenticate(&request, &form, base)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncoded(form).utf8)
        let (status, json) = try await send(request, session: session)
        // A server error is a passing trouble: the tokens are kept.
        if status >= 500 { throw MCPSignInError.unreachable }
        guard status == 200, case .object(let answer)? = json, let access = answer["access_token"]?.text, !access.isEmpty,
              answer["token_type"]?.text.map({ $0.lowercased() == "bearer" }) ?? true
        else { throw MCPSignInError.refused(refusal(status, json)) }
        var credentials = base
        credentials.accessToken = access
        if let refresh = answer["refresh_token"]?.text, !refresh.isEmpty { credentials.refreshToken = refresh }
        let lifetime = answer["expires_in"]?.integer.map { TimeInterval(max($0, 0)) }
        credentials.expiresAt = lifetime.map { now.addingTimeInterval($0) }
        credentials.refreshAt = lifetime.map { now.addingTimeInterval(max($0 - MCPAccountAccess.margin, $0 / 2)) }
        if let scope = answer["scope"]?.text { credentials.scope = scope }
        return credentials
    }

    /// The client secret, when there is one: in the header or in the form.
    private static func authenticate(_ request: inout URLRequest, _ form: inout [(String, String)], _ credentials: MCPCredentials) {
        guard let secret = credentials.clientSecret else { return }
        if credentials.secretInHeader {
            // RFC 6749 §2.3.1: each part form-encoded first.
            let pair = "\(formEncoded(credentials.clientID)):\(formEncoded(secret))"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        } else {
            form.append(("client_secret", secret))
        }
    }

    // MARK: - HTTP

    /// A GET for JSON: its status and body; nil when nothing answered.
    static func getJSON(_ url: URL, session: URLSession) async -> (Int, JSONValue?)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return try? await send(request, session: session)
    }

    /// Sends a request: its status and its body as JSON (nil when it is not). `unreachable` when nothing answered.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Int, JSONValue?) {
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            throw MCPSignInError.unreachable
        }
        return (http.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// What a refusal says: its `error_description`, its `error`, or its status.
    static func refusal(_ status: Int, _ json: JSONValue?) -> String {
        if case .object(let answer)? = json {
            if let description = answer["error_description"]?.text, !description.isEmpty { return description }
            if let error = answer["error"]?.text, !error.isEmpty { return error }
        }
        return "HTTP \(status)"
    }

    // MARK: - Addresses

    /// `/.well-known/<name>` for the address: with its path after (RFC 9728 §3.1, RFC 8414 §3.1), then at the root.
    static func wellKnown(_ name: String, for url: URL) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return [] }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.query = nil
        components.fragment = nil
        var urls: [URL] = []
        if !path.isEmpty {
            components.path = "/.well-known/\(name)\(path)"
            if let url = components.url { urls.append(url) }
        }
        components.path = "/.well-known/\(name)"
        if let url = components.url { urls.append(url) }
        return urls
    }

    /// Where an authorization server's metadata may be: RFC 8414's place, then OpenID Connect's two.
    static func wellKnownServer(_ issuer: URL) -> [URL] {
        var urls = wellKnown("oauth-authorization-server", for: issuer)
        let openID = wellKnown("openid-configuration", for: issuer)
        urls += openID
        if var components = URLComponents(url: issuer, resolvingAgainstBaseURL: true), !components.path.isEmpty,
           components.path != "/"
        {
            components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
                + "/.well-known/openid-configuration"
            components.query = nil
            if let url = components.url { urls.insert(url, at: urls.count - 1) }
        }
        return unique(urls)
    }

    /// `scheme://host:port/`.
    static func origin(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true), components.host != nil else {
            return nil
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func parts(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
        }
        guard let first = parts(a), let second = parts(b) else { return false }
        return first == second
    }

    /// The service's address as MCP names it: without query nor fragment, its scheme and host in lowercase.
    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    // MARK: - Encoding

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Only the unreserved characters are left as they are.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func formEncoded(_ items: [(String, String)]) -> String {
        items.map { "\(formEncoded($0.0))=\(formEncoded($0.1))" }.joined(separator: "&")
    }
}

// MARK: - What the client sends

/// What a connected tool's client sends to prove it may use the service (`Authorization: Bearer`).
public protocol MCPAuthorizing: Sendable {
    /// The token for the next request; nil: none is sent. Throws `MCPError.unauthorized` when signing in again is needed.
    func token() async throws -> String?
    /// The service refused `rejected` (401): a new token, or `MCPError.unauthorized` when there is none to get.
    func renewed(after rejected: String?) async throws -> String
}

/// A token the user pasted: it never changes.
public struct MCPPastedToken: MCPAuthorizing {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func token() async throws -> String? { value }

    public func renewed(after rejected: String?) async throws -> String { throw MCPError.unauthorized }
}

/// The user's account, once signed in: its access token, refreshed shortly before it expires or once the service
/// refused it, the new tokens kept where `save` puts them (the keychain). Each tool needs only one: two would refresh the
/// same token twice, and a service that changes its refresh token at each use takes the second use for a theft.
public actor MCPAccountAccess: MCPAuthorizing {
    /// How long before its expiry a token is refreshed (halfway through a shorter life).
    public static let margin: TimeInterval = 60

    private let load: @Sendable () -> MCPCredentials?
    private let save: @Sendable (MCPCredentials) -> Void
    private let session: URLSession
    private var credentials: MCPCredentials?
    private var loaded = false
    private var refreshing: Task<MCPCredentials, any Error>?
    /// The refresh token the service refused: not tried again until the user signs in again.
    private var refused: String?

    /// `load`: the saved credentials (read at first use, and again after a refusal); `save`: keeps refreshed ones.
    public init(load: @escaping @Sendable () -> MCPCredentials?, save: @escaping @Sendable (MCPCredentials) -> Void,
                configuration: URLSessionConfiguration = .ephemeral)
    {
        self.load = load
        self.save = save
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// Reads the saved credentials again: after signing in again.
    public func reload() {
        credentials = load()
        loaded = true
        refused = nil
    }

    public func token() async throws -> String? {
        guard let current = current() else { throw MCPError.unauthorized }
        guard current.isDue(), current.refreshToken != refused else { return current.accessToken }
        return try await refresh(current).accessToken
    }

    public func renewed(after rejected: String?) async throws -> String {
        // The saved ones: the tool was removed when there are none.
        guard let saved = load() else { throw MCPError.unauthorized }
        credentials = saved
        loaded = true
        // Signed in again, or refreshed by another request, meanwhile: the new token.
        if saved.accessToken != rejected {
            if saved.refreshToken != refused { refused = nil }
            return saved.accessToken
        }
        return try await refresh(saved).accessToken
    }

    private func current() -> MCPCredentials? {
        if !loaded {
            credentials = load()
            loaded = true
        }
        return credentials
    }

    /// One refresh at a time: a request that needs one while another is under way waits for it.
    private func refresh(_ old: MCPCredentials) async throws -> MCPCredentials {
        if let refreshing { return try await refreshing.value }
        guard let token = old.refreshToken, token != refused else { throw MCPError.unauthorized }
        let session = session
        let task = Task { () async throws -> MCPCredentials in
            do {
                return try await MCPAuthorization.refreshed(old, session: session)
            } catch MCPSignInError.refused {
                throw MCPError.unauthorized
            } catch {
                throw MCPError.unreachable
            }
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let new = try await task.value
            credentials = new
            save(new)
            return new
        } catch MCPError.unauthorized {
            // Signed in again while the refresh was refused: the new credentials.
            if let saved = load(), saved.refreshToken != token {
                credentials = saved
                return saved
            }
            refused = token
            throw MCPError.unauthorized
        }
    }
}
