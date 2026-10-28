import FakeHomeAssistant
import Foundation
import Testing

@testable import VoiceCore

// Signing in to a connected tool with the user's account, against the pretend Home Assistant's authorization server
// (FakeHomeAssistant.Accounts): discovery, registration, PKCE, the tokens, their refresh, a refused refresh.

/// The pretend Home Assistant, signing apps in.
private func home(_ accounts: FakeHomeAssistant.Accounts = .init()) async throws -> FakeHomeAssistant {
    var options = FakeHomeAssistant.Options()
    options.accounts = accounts
    let server = FakeHomeAssistant(options: options)
    try await server.start()
    return server
}

/// The pretend user's browser: opens the page (the pretend user agrees at once), then follows the service's answer back
/// to this Mac. The status of the page this Mac answered with.
@discardableResult
private func browse(_ page: URL) async throws -> Int {
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    let (_, response) = try await session.data(from: page)
    let answer = try #require(response as? HTTPURLResponse)
    try #require(answer.statusCode == 302)
    let back = try #require(answer.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0) })
    let (_, final) = try await session.data(from: back)
    return (final as? HTTPURLResponse)?.statusCode ?? 0
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest?
    {
        nil
    }
}

/// Signs in as the app does, the pretend user's browser in place of the real one.
private func signIn(_ server: FakeHomeAssistant) async throws -> MCPCredentials {
    let signIn = MCPAccountSignIn(address: server.address)
    let page = try await signIn.prepare()
    async let credentials = signIn.finish()
    #expect(try await browse(page) == 200)
    return try await credentials
}

/// Where the credentials are kept (the keychain, in the app).
private final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: MCPCredentials?
    private(set) var saves = 0

    init(_ credentials: MCPCredentials?) {
        kept = credentials
    }

    var credentials: MCPCredentials? {
        get { lock.withLock { kept } }
        set { lock.withLock { kept = newValue } }
    }

    func access() -> MCPAccountAccess {
        MCPAccountAccess(load: { self.credentials }, save: { new in
            self.lock.withLock {
                self.kept = new
                self.saves += 1
            }
        })
    }
}

private actor Collected {
    var reports: [ConnectedToolReport] = []
    func add(_ report: ConnectedToolReport) { reports.append(report) }
}

@Suite("Connected tools: signing in with an account", .serialized)
struct MCPAuthorizationTests {
    @Test func pkceIsRFC7636s() {
        // RFC 7636, appendix B.
        #expect(MCPPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = MCPPKCE()
        #expect(first.verifier.count == 43)
        #expect(first.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) })
        #expect(first.verifier != MCPPKCE().verifier)
        #expect(first.challenge.count == 43)
    }

    @Test func readsAChallenge() {
        let parameters = MCPAuthorization.challengeParameters(
            #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read files:write", error=invalid_token"#)
        #expect(parameters["resource_metadata"] == "https://mcp.example.com/.well-known/oauth-protected-resource")
        #expect(parameters["scope"] == "files:read files:write")
        #expect(parameters["error"] == "invalid_token")
        #expect(MCPAuthorization.challengeParameters(#"Bearer realm="a \"b\"""#)["realm"] == #"a "b""#)
        #expect(MCPAuthorization.challengeParameters("Bearer").isEmpty)
    }

    @Test func wellKnownAddressesComeBeforeAndAfterThePath() {
        let address = URL(string: "https://example.com/api/mcp?x=1")!
        #expect(MCPAuthorization.wellKnown("oauth-protected-resource", for: address).map(\.absoluteString) == [
            "https://example.com/.well-known/oauth-protected-resource/api/mcp",
            "https://example.com/.well-known/oauth-protected-resource",
        ])
        #expect(MCPAuthorization.wellKnownServer(URL(string: "https://auth.example.com/tenant")!).map(\.absoluteString) == [
            "https://auth.example.com/.well-known/oauth-authorization-server/tenant",
            "https://auth.example.com/.well-known/oauth-authorization-server",
            "https://auth.example.com/.well-known/openid-configuration/tenant",
            "https://auth.example.com/tenant/.well-known/openid-configuration",
            "https://auth.example.com/.well-known/openid-configuration",
        ])
    }

    @Test func signInAddressesAreHTTPSButOnTheHomeNetwork() {
        func server(_ base: String) -> MCPAuthorizationServer? {
            MCPAuthorization.authorizationServer(["authorization_endpoint": .string("\(base)/authorize"),
                                                  "token_endpoint": "/token"], issuer: URL(string: base)!)
        }
        #expect(server("https://auth.example.com")?.tokenEndpoint.absoluteString == "https://auth.example.com/token")
        #expect(server("http://homeassistant.local:8123")?.tokenEndpoint.absoluteString
            == "http://homeassistant.local:8123/token")
        #expect(server("http://192.168.1.20:8123") != nil)
        #expect(server("http://auth.example.com") == nil)
        // A server that lists its PKCE methods without S256 cannot be used.
        #expect(MCPAuthorization.authorizationServer(["authorization_endpoint": "/a", "token_endpoint": "/t",
                                                      "code_challenge_methods_supported": ["plain"]],
                                                     issuer: URL(string: "https://auth.example.com")!) == nil)
    }

    @Test func discoversHomeAssistantsAuthorizationServer() async throws {
        let server = try await home()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"
        let plan = try await MCPAuthorization.discover(server.address, session: URLSession(configuration: .ephemeral))
        #expect(plan.server.authorizationEndpoint.absoluteString == "\(origin)/auth/authorize")
        #expect(plan.server.tokenEndpoint.absoluteString == "\(origin)/auth/token")
        #expect(plan.server.revocationEndpoint?.absoluteString == "\(origin)/auth/revoke")
        #expect(plan.server.registrationEndpoint == nil)
        // Its protected resource metadata names its origin.
        #expect(plan.resource == origin)
        #expect(plan.scope == nil)
    }

    @Test func anOlderHomeAssistantIsFoundAtItsOriginWithRelativeAddresses() async throws {
        var accounts = FakeHomeAssistant.Accounts()
        accounts.resourceMetadata = false
        accounts.relativeEndpoints = true
        let server = try await home(accounts)
        defer { server.stop() }
        let plan = try await MCPAuthorization.discover(server.address, session: URLSession(configuration: .ephemeral))
        #expect(plan.server.authorizationEndpoint.absoluteString == "http://127.0.0.1:\(server.port)/auth/authorize")
        #expect(plan.server.tokenEndpoint.absoluteString == "http://127.0.0.1:\(server.port)/auth/token")
        #expect(plan.resource == server.address.absoluteString)
    }

    @Test func aServiceWithoutAccountsOffersNoSignIn() async throws {
        var options = FakeHomeAssistant.Options()
        options.token = "a-token"
        let server = FakeHomeAssistant(options: options)
        try await server.start()
        let address = server.address
        await #expect(throws: MCPSignInError.notOffered) {
            try await MCPAuthorization.discover(address, session: URLSession(configuration: .ephemeral))
        }
        server.stop()
        // Nothing answers any more.
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: MCPSignInError.unreachable) {
            try await MCPAuthorization.discover(address, session: URLSession(configuration: .ephemeral))
        }
    }

    @Test func signsInAsHomeAssistantAsksWithPKCE() async throws {
        let server = try await home()
        defer { server.stop() }
        let signIn = MCPAccountSignIn(address: server.address)
        let page = try await signIn.prepare()
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(page.path() == "/auth/authorize")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"]?.count == 43)
        #expect((query["state"]?.count ?? 0) >= 32)
        #expect(query["resource"] == "http://127.0.0.1:\(server.port)")
        // Home Assistant registers no app: the app is a loopback URL, and the way back shares its scheme and host.
        let client = try #require(query["client_id"].flatMap { URL(string: $0) })
        let back = try #require(query["redirect_uri"].flatMap { URL(string: $0) })
        #expect(client.host() == "127.0.0.1" && back.host() == "127.0.0.1" && client.port == back.port)
        #expect(client.path() == "/openmae" && back.path() == "/callback")
        async let signedIn = signIn.finish()
        #expect(try await browse(page) == 200)
        let credentials = try await signedIn
        #expect(credentials.clientID == client.absoluteString)
        #expect(credentials.refreshToken != nil)
        #expect(credentials.tokenEndpoint.path() == "/auth/token")
        let expiresIn = try #require(credentials.expiresAt).timeIntervalSinceNow
        #expect(expiresIn > 1700 && expiresIn <= 1800)
        #expect(!credentials.description.contains(credentials.accessToken))

        let saved = Saved(credentials)
        let mcp = MCPClient(address: server.address, authorization: saved.access())
        // Nothing was refused: Home Assistant would have shown "Login attempt failed".
        #expect(try await mcp.listTools().count == 10)
        #expect(server.refusals == 0 && server.refreshes == 0)
    }

    @Test func findsMetadataThatOnlyThe401Names() async throws {
        var accounts = FakeHomeAssistant.Accounts()
        accounts.metadataElsewhere = true
        accounts.registration = true
        let server = try await home(accounts)
        defer { server.stop() }
        let plan = try await MCPAuthorization.discover(server.address, session: URLSession(configuration: .ephemeral))
        #expect(plan.server.registrationEndpoint?.absoluteString == "http://127.0.0.1:\(server.port)/register")
        #expect(plan.resource == "http://127.0.0.1:\(server.port)")
        #expect(server.refusals == 1)
    }

    @Test func registersTheAppWhenTheServiceLetsAppsRegister() async throws {
        var accounts = FakeHomeAssistant.Accounts()
        accounts.registration = true
        let server = try await home(accounts)
        defer { server.stop() }
        let credentials = try await signIn(server)
        #expect(server.registeredApps == [credentials.clientID])
        #expect(credentials.clientSecret == nil)
        let mcp = MCPClient(address: server.address, authorization: Saved(credentials).access())
        #expect(try await mcp.listTools().count == 10)
    }

    @Test func aWrongVerifierGetsNoToken() async throws {
        let server = try await home()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let plan = try await MCPAuthorization.discover(server.address, session: session)
        let back = URL(string: "http://127.0.0.1:9/callback")!
        let client = MCPClientIdentity(id: "http://127.0.0.1:9/openmae")
        let page = MCPAuthorization.authorizationURL(plan, client: client.id, redirect: back, pkce: MCPPKCE(), state: "s")
        let browser = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let (_, response) = try await browser.data(from: page)
        let location = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"))
        let code = try #require(URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value)
        await #expect(throws: MCPSignInError.refused("Invalid code verifier")) {
            try await MCPAuthorization.exchange(code: code, plan: plan, client: client, redirect: back, pkce: MCPPKCE(),
                                                session: session)
        }
    }

    @Test func refreshesATokenAboutToExpireBeforeUsingIt() async throws {
        var accounts = FakeHomeAssistant.Accounts()
        accounts.lifetime = 2
        let server = try await home(accounts)
        defer { server.stop() }
        let credentials = try await signIn(server)
        // Home Assistant's half-hour tokens are refreshed a minute before they expire; a two-second one, after one.
        let refreshAt = try #require(credentials.refreshAt).timeIntervalSinceNow
        #expect(refreshAt > 0.5 && refreshAt <= 1)
        let saved = Saved(credentials)
        let mcp = MCPClient(address: server.address, authorization: saved.access())
        let refusals = server.refusals
        try await Task.sleep(for: .seconds(1.1))
        #expect(try await mcp.listTools().count == 10)
        // Refreshed once, before the first of the three requests, which the service took at once.
        #expect(server.refreshes == 1)
        #expect(server.refusals == refusals)
        #expect(saved.credentials?.accessToken != credentials.accessToken)
        // Home Assistant gives no new refresh token: the old one is kept.
        #expect(saved.credentials?.refreshToken == credentials.refreshToken)
        #expect(saved.saves == 1)
    }

    @Test func refreshesATokenTheServiceRefusesAndSendsTheRequestAgain() async throws {
        let server = try await home()
        defer { server.stop() }
        let saved = Saved(try await signIn(server))
        let mcp = MCPClient(address: server.address, authorization: saved.access())
        #expect(try await mcp.listTools().count == 10)
        let refusals = server.refusals
        server.expireAccessTokens()
        #expect(try await mcp.call("HassTurnOn", arguments: ["area": "salon"]).isError == false)
        #expect(server.refusals == refusals + 1)
        #expect(server.refreshes == 1)
        #expect(server.calls.map(\.name) == ["HassTurnOn"])
    }

    @Test func keepsTheNewRefreshTokenOfAServiceThatChangesIt() async throws {
        var accounts = FakeHomeAssistant.Accounts()
        accounts.rotatesRefreshTokens = true
        let server = try await home(accounts)
        defer { server.stop() }
        let first = try await signIn(server)
        let saved = Saved(first)
        let mcp = MCPClient(address: server.address, authorization: saved.access())
        server.expireAccessTokens()
        #expect(try await mcp.listTools().count == 10)
        let second = try #require(saved.credentials)
        #expect(second.refreshToken != first.refreshToken)
        server.expireAccessTokens()
        #expect(try await mcp.listTools().count == 10)
        #expect(server.refreshes == 2)
    }

    @Test func aRefusedRefreshAsksToReconnect() async throws {
        var accounts = FakeHomeAssistant.Accounts()
        accounts.refusesRefresh = true
        let server = try await home(accounts)
        defer { server.stop() }
        let saved = Saved(try await signIn(server))
        let access = saved.access()
        let mcp = MCPClient(address: server.address, authorization: access)
        #expect(try await mcp.listTools().count == 10)
        server.expireAccessTokens()
        await #expect(throws: MCPError.unauthorized) { try await mcp.listTools() }
        // The tool's state: "To reconnect".
        var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .account)
        settings.actions = [.init(tool: MCPTool(name: "HassTurnOn", description: ""), enabled: true)]
        let tools = ConnectedTools()
        let collected = Collected()
        await tools.observe { report in Task { await collected.add(report) } }
        await tools.configure([.init(settings: settings, client: mcp)])
        await #expect(throws: ToolRefusal.self) {
            try await tools.perform(ToolCall(name: "HassTurnOn", arguments: ["area": "salon"]),
                                    context: ToolContext(now: Date(), language: .french))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await collected.reports.contains(.state(settings.id, .needsReconnect)))
        #expect(server.calls.isEmpty)

        // Signing in again: the same access takes the new credentials.
        var options = server.options
        options.accounts?.refusesRefresh = false
        server.options = options
        saved.credentials = try await signIn(server)
        await access.reload()
        #expect(try await mcp.listTools().count == 10)
    }

    @Test func revokingForgetsTheRefreshToken() async throws {
        let server = try await home()
        defer { server.stop() }
        let credentials = try await signIn(server)
        #expect(server.liveRefreshTokens == 1)
        await MCPAuthorization.revoke(credentials, session: URLSession(configuration: .ephemeral))
        #expect(server.liveRefreshTokens == 0)
    }

    @Test func closingTheBrowserCancels() async throws {
        let server = try await home()
        defer { server.stop() }
        let signIn = MCPAccountSignIn(address: server.address)
        _ = try await signIn.prepare()
        let signedIn = Task { try await signIn.finish() }
        try await Task.sleep(for: .milliseconds(50))
        await signIn.cancel()
        await #expect(throws: MCPSignInError.cancelled) { try await signedIn.value }
    }

    @Test func theWayBackSendsTheBrowserToTheApp() async throws {
        let server = try await home()
        defer { server.stop() }
        let signIn = MCPAccountSignIn(address: server.address, returnTo: URL(string: "openmae://signed-in")!)
        let page = try await signIn.prepare()
        async let signedIn = signIn.finish()
        let browser = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let (_, response) = try await browser.data(from: page)
        let back = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0) })
        let (_, final) = try await browser.data(from: back)
        #expect((final as? HTTPURLResponse)?.statusCode == 302)
        #expect((final as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") == "openmae://signed-in")
        _ = try await signedIn
    }
}
