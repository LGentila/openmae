import CryptoKit
import Foundation
import Network
import VoiceCore

/// A pretend Home Assistant for the tests and the benchmarks: its MCP server (the "Model Context Protocol Server"
/// integration) on a local port, Streamable HTTP at `/api/mcp`, with the tools Home Assistant lists for its Assist API,
/// named, described and shaped as it sends them (without annotations, as older versions do), over a small house:
/// lights in four rooms, a thermostat and two covers. It changes its house as the calls ask and answers as Home
/// Assistant does (an intent's response as JSON text; `isError` and "Error calling tool: …" when nothing matches).
///
/// How it answers depends on `options`: JSON (Home Assistant's way) or a stream of server-sent events, with a session or
/// not, a token to check or not, the list in pages, no answer at all. With `accounts`, it also signs apps in as Home
/// Assistant does (OAuth with PKCE, its apps named by URLs), or as a service that registers them.
public final class FakeHomeAssistant: @unchecked Sendable {
    public struct Options: Sendable {
        /// Answers as a stream of server-sent events instead of JSON.
        public var stream = false
        /// Gives a session (`Mcp-Session-Id`) at `initialize` and asks for it afterwards.
        public var sessions = false
        /// The token it accepts (`Authorization: Bearer`); nil: any request, with a token or not.
        public var token: String?
        /// Tools per page of `tools/list`; nil: all at once.
        public var pageSize: Int?
        /// Never answers (the connection stays open, silent).
        public var silent = false
        /// Before its answer in a stream, says its tools changed.
        public var saysToolsChanged = false
        /// More devices in the house, for a long `GetLiveContext`.
        public var extraDevices = 0
        /// Signs apps in with the user's account, and takes only the access tokens it gave (`token` is not used).
        public var accounts: Accounts?

        public init() {}
    }

    /// How it signs apps in (OAuth 2.1 with PKCE): its pretend user always agrees at once.
    public struct Accounts: Sendable {
        /// Its protected resource metadata at `/.well-known/oauth-protected-resource`, named by its 401's
        /// `WWW-Authenticate`, as Home Assistant 2026 has them; false: only its authorization server's metadata.
        public var resourceMetadata = true
        /// Its metadata at other addresses, as some services have them: the protected resource's only named by the 401's
        /// `WWW-Authenticate`, the authorization server's under its own path (`/auth-server`).
        public var metadataElsewhere = false
        /// The addresses in its metadata relative, as Home Assistant gives them when it does not know its own URL.
        public var relativeEndpoints = false
        /// Registers apps at `/register` (RFC 7591), as many services do; false: an app is a URL, and the way back must
        /// share its scheme and host (Home Assistant's IndieAuth).
        public var registration = false
        /// How long an access token lasts, in seconds (Home Assistant's: 30 minutes).
        public var lifetime = 1800
        /// Refuses every refresh, as after the user took the app's access back.
        public var refusesRefresh = false
        /// Gives a new refresh token at each refresh, and refuses the old one.
        public var rotatesRefreshTokens = false

        public init() {}
    }

    public struct Call: Sendable, Equatable {
        public var name: String
        public var arguments: [String: JSONValue]

        public init(name: String, arguments: [String: JSONValue]) {
            self.name = name
            self.arguments = arguments
        }
    }

    struct Device: Sendable {
        var id: String
        var name: String
        var domain: String
        var area: String
        var on = false
        var brightness: Int?
        var target: Double?
        var current: Double?
        var position: Int?
        var deviceClass: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake-home-assistant")
    private var listener: NWListener?
    // Guarded by `lock`.
    private var currentOptions: Options
    private var made: [Call] = []
    private var devices: [Device]
    private var session: String?
    private var heldConnections: [NWConnection] = []
    private var codes: [String: Grant] = [:]
    /// Access token → when it expires.
    private var accessTokens: [String: Date] = [:]
    /// Refresh token → the app it was given to.
    private var refreshTokens: [String: String] = [:]
    /// Registered app → its ways back.
    private var registered: [String: [String]] = [:]
    private var refreshCount = 0
    private var refusalCount = 0
    public private(set) var port: UInt16 = 0

    private struct Grant {
        var client: String
        var redirect: String
        var challenge: String
    }

    public init(options: Options = Options()) {
        currentOptions = options
        devices = Self.house
        for i in 0..<options.extraDevices {
            devices.append(Device(id: "sensor.capteur_\(i)", name: "Capteur \(i)", domain: "sensor",
                                  area: ["Salon", "Cuisine", "Chambre", "Bureau"][i % 4], current: 20 + Double(i % 7) / 2))
        }
    }

    public var address: URL { URL(string: "http://127.0.0.1:\(port)/api/mcp")! }

    public var options: Options {
        get { lock.withLock { currentOptions } }
        set { lock.withLock { currentOptions = newValue } }
    }

    /// The tool calls it received, in order.
    public var calls: [Call] { lock.withLock { made } }

    /// Forgets its session: the next request in it gets a 404.
    public func forgetSession() {
        lock.withLock { session = "forgotten" }
    }

    /// The access tokens it gave expire now (their refresh tokens still work).
    public func expireAccessTokens() {
        lock.withLock {
            for token in accessTokens.keys { accessTokens[token] = .distantPast }
        }
    }

    /// How many refreshes it did, and how many requests to its MCP server it refused (401).
    public var refreshes: Int { lock.withLock { refreshCount } }
    public var refusals: Int { lock.withLock { refusalCount } }
    /// The apps registered, by id.
    public var registeredApps: [String] { lock.withLock { Array(registered.keys) } }
    /// The refresh tokens it still takes.
    public var liveRefreshTokens: Int { lock.withLock { refreshTokens.count } }

    /// Whether a light (by its name) is on.
    public func isOn(_ name: String) -> Bool? {
        lock.withLock { devices.first { $0.name == name }?.on }
    }

    public func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            self?.receive(connection, buffer: Data())
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: queue)
        for await port in ready.stream {
            self.port = port
            break
        }
    }

    public func stop() {
        listener?.cancel()
        lock.withLock { heldConnections.forEach { $0.cancel() } }
    }

    // MARK: - HTTP

    private struct Request {
        var method: String
        var path: String
        var query = ""
        var headers: [String: String]
        var body: Data
    }

    private struct Response {
        var status: Int
        var body = Data()
        var type = "application/json"
        var headers: [String: String] = [:]
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                if self.options.silent {
                    self.lock.withLock { self.heldConnections.append(connection) }
                    return
                }
                Self.send(self.route(request), on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(parts[1])
        let path = String(target.prefix { $0 != "?" })
        return Request(method: String(parts[0]), path: path, query: String(target.dropFirst(path.count + 1)),
                       headers: headers, body: Data(body.prefix(length)))
    }

    private static func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.status < 300 ? "OK" : "Error")\r\n"
            + "Content-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(_ request: Request) -> Response {
        let options = self.options
        if let accounts = options.accounts, let response = signIn(request, accounts) { return response }
        guard request.path == "/api/mcp" else { return Response(status: 404, body: Data("404: Not Found".utf8), type: "text/plain") }
        guard request.method == "POST" else { return Response(status: 405, type: "text/plain") }
        if let accounts = options.accounts {
            let authorization = request.headers["authorization"] ?? ""
            let token = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : ""
            let valid = lock.withLock { accessTokens[token].map { $0 > Date() } ?? false }
            if !valid {
                lock.withLock { refusalCount += 1 }
                let headers = accounts.resourceMetadata
                    ? ["WWW-Authenticate": "Bearer resource_metadata=\"\(origin)\(Self.resourceMetadataPath(accounts))\""] : [:]
                return Response(status: 401, body: Data("401: Unauthorized".utf8), type: "text/plain", headers: headers)
            }
        } else if let token = options.token, request.headers["authorization"] != "Bearer \(token)" {
            return Response(status: 401, body: Data("401: Unauthorized".utf8), type: "text/plain")
        }
        guard (request.headers["accept"] ?? "").contains("application/json") else {
            return Response(status: 400, body: Data("Client must accept application/json".utf8), type: "text/plain")
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body),
              case .object(let object) = message, let method = object["method"]?.text
        else {
            return Response(status: 400, body: Data("Request must be a JSON-RPC message".utf8), type: "text/plain")
        }
        var headers: [String: String] = [:]
        if options.sessions {
            let known = lock.withLock { session }
            if method == "initialize" {
                let new = UUID().uuidString
                lock.withLock { session = new }
                headers["Mcp-Session-Id"] = new
            } else if request.headers["mcp-session-id"] == nil {
                return Response(status: 400, body: Data("Missing session".utf8), type: "text/plain")
            } else if request.headers["mcp-session-id"] != known {
                return Response(status: 404, body: Data("Session not found".utf8), type: "text/plain")
            }
        }
        guard let id = object["id"] else { return Response(status: 202, type: "text/plain", headers: headers) }
        let params: [String: JSONValue] = if case .object(let p)? = object["params"] { p } else { [:] }
        let reply: JSONValue
        switch method {
        case "initialize":
            reply = ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
                "serverInfo": ["name": "home-assistant", "version": "2026.10.0"],
            ]]
        case "tools/list":
            let tools = Self.tools
            let start = params["cursor"]?.text.flatMap { Int($0) } ?? 0
            let end = min(tools.count, start + (options.pageSize ?? tools.count))
            var result: [String: JSONValue] = ["tools": .array(Array(tools[start..<end]))]
            if end < tools.count { result["nextCursor"] = .string(String(end)) }
            reply = ["jsonrpc": "2.0", "id": id, "result": .object(result)]
        case "tools/call":
            let name = params["name"]?.text ?? ""
            let arguments: [String: JSONValue] = if case .object(let a)? = params["arguments"] { a } else { [:] }
            lock.withLock { made.append(Call(name: name, arguments: arguments)) }
            let (text, isError) = call(name, arguments)
            reply = ["jsonrpc": "2.0", "id": id, "result": [
                "content": [["type": "text", "text": .string(text)]], "isError": .bool(isError),
            ]]
        case "ping":
            reply = ["jsonrpc": "2.0", "id": id, "result": [:]]
        default:
            reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found", "data": .string(method)]]
        }
        let json = (try? JSONEncoder().encode(reply)) ?? Data()
        guard options.stream else { return Response(status: 200, body: json, headers: headers) }
        var events = ""
        if options.saysToolsChanged {
            events += "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n"
        }
        events += ": a comment line\n"
        events += "event: message\nid: 1\ndata: " + String(decoding: json, as: UTF8.self) + "\n\n"
        return Response(status: 200, body: Data(events.utf8), type: "text/event-stream", headers: headers)
    }

    // MARK: - Signing in

    private var origin: String { "http://127.0.0.1:\(port)" }

    private static func resourceMetadataPath(_ accounts: Accounts) -> String {
        accounts.metadataElsewhere ? "/api/mcp-metadata" : "/.well-known/oauth-protected-resource"
    }

    /// Its metadata, registration, sign-in page, tokens and revocation; nil for any other request.
    private func signIn(_ request: Request, _ accounts: Accounts) -> Response? {
        let base = accounts.relativeEndpoints ? "" : origin
        switch (request.method, request.path) {
        case ("GET", Self.resourceMetadataPath(accounts)):
            guard accounts.resourceMetadata else { return Response(status: 404, type: "text/plain") }
            let issuer = accounts.metadataElsewhere ? "\(origin)/auth-server" : origin
            return json(200, ["resource": .string(origin), "authorization_servers": [.string(issuer)]])
        case ("GET", accounts.metadataElsewhere ? "/.well-known/oauth-authorization-server/auth-server"
            : "/.well-known/oauth-authorization-server"):
            var metadata: [String: JSONValue] = [
                "authorization_endpoint": .string("\(base)/auth/authorize"), "token_endpoint": .string("\(base)/auth/token"),
                "revocation_endpoint": .string("\(base)/auth/revoke"),
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"], "response_types_supported": ["code"],
            ]
            if accounts.registration { metadata["registration_endpoint"] = .string("\(base)/register") }
            return json(200, .object(metadata))
        case ("POST", "/register") where accounts.registration:
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: request.body), case .object(let app) = body,
                  case .array(let ways)? = app["redirect_uris"], !ways.isEmpty
            else { return json(400, ["error": "invalid_client_metadata"]) }
            let id = "app-\(UUID().uuidString.prefix(8))"
            lock.withLock { registered[id] = ways.compactMap(\.text) }
            return json(201, ["client_id": .string(id), "redirect_uris": .array(ways), "token_endpoint_auth_method": "none"])
        case ("GET", "/auth/authorize"):
            let query = Self.form(request.query)
            guard query["response_type"] == "code", let client = query["client_id"], let back = query["redirect_uri"],
                  allows(client, back, accounts), let state = query["state"]
            else { return Response(status: 400, body: Data("Invalid client id or redirect uri".utf8), type: "text/plain") }
            guard let challenge = query["code_challenge"], challenge.count == 43, query["code_challenge_method"] == "S256"
            else { return Response(status: 400, body: Data("PKCE required".utf8), type: "text/plain") }
            let code = Self.random()
            lock.withLock { codes[code] = Grant(client: client, redirect: back, challenge: challenge) }
            var way = URLComponents(string: back)!
            way.queryItems = (way.queryItems ?? []) + [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
            return Response(status: 302, type: "text/plain", headers: ["Location": way.url!.absoluteString])
        case ("POST", "/auth/token"):
            return token(Self.form(String(decoding: request.body, as: UTF8.self)), accounts)
        case ("POST", "/auth/revoke"):
            let form = Self.form(String(decoding: request.body, as: UTF8.self))
            lock.withLock {
                if let token = form["token"] { refreshTokens[token] = nil }
            }
            return Response(status: 200, type: "text/plain")
        default:
            return nil
        }
    }

    /// Home Assistant's rule for an app that is a URL: the way back shares its scheme and host; a registered app's
    /// ways back are the ones it gave.
    private func allows(_ client: String, _ back: String, _ accounts: Accounts) -> Bool {
        if accounts.registration { return lock.withLock { registered[client]?.contains(back) ?? false } }
        guard let app = URLComponents(string: client), let way = URLComponents(string: back), app.host != nil else {
            return false
        }
        return app.scheme == way.scheme && app.host == way.host && app.port == way.port
    }

    private func token(_ form: [String: String], _ accounts: Accounts) -> Response {
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let grant = lock.withLock({ codes.removeValue(forKey: code) }),
                  form["client_id"] == grant.client
            else { return json(400, ["error": "invalid_request", "error_description": "Invalid code"]) }
            let verifier = form["code_verifier"] ?? ""
            let hashed = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            guard hashed == grant.challenge else {
                return json(400, ["error": "invalid_grant", "error_description": "Invalid code verifier"])
            }
            let (access, refresh) = lock.withLock { () -> (String, String) in
                let access = Self.random()
                let refresh = Self.random()
                accessTokens[access] = Date().addingTimeInterval(TimeInterval(accounts.lifetime))
                refreshTokens[refresh] = grant.client
                return (access, refresh)
            }
            return json(200, ["access_token": .string(access), "token_type": "Bearer", "refresh_token": .string(refresh),
                              "expires_in": .int(accounts.lifetime)])
        case "refresh_token":
            guard !accounts.refusesRefresh, let refresh = form["refresh_token"],
                  lock.withLock({ refreshTokens[refresh] }) == form["client_id"], form["client_id"] != nil
            else { return json(400, ["error": "invalid_grant"]) }
            let (access, new) = lock.withLock { () -> (String, String?) in
                refreshCount += 1
                let access = Self.random()
                accessTokens[access] = Date().addingTimeInterval(TimeInterval(accounts.lifetime))
                guard accounts.rotatesRefreshTokens else { return (access, nil) }
                let new = Self.random()
                refreshTokens[new] = refreshTokens.removeValue(forKey: refresh)
                return (access, new)
            }
            var answer: [String: JSONValue] = ["access_token": .string(access), "token_type": "Bearer",
                                               "expires_in": .int(accounts.lifetime)]
            if let new { answer["refresh_token"] = .string(new) }
            return json(200, .object(answer))
        default:
            return json(400, ["error": "unsupported_grant_type"])
        }
    }

    private func json(_ status: Int, _ value: JSONValue) -> Response {
        Response(status: status, body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    /// `a=1&b=x%20y` → its values.
    private static func form(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let name = parts.first, values[name] == nil { values[name] = parts.count > 1 ? parts[1] : "" }
        }
        return values
    }

    private static func random() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - The house

    static let house: [Device] = [
        Device(id: "light.plafonnier_du_salon", name: "Plafonnier du salon", domain: "light", area: "Salon"),
        Device(id: "light.lampe_du_salon", name: "Lampe du salon", domain: "light", area: "Salon", on: true,
               brightness: 60),
        Device(id: "light.lumiere_de_la_cuisine", name: "Lumière de la cuisine", domain: "light", area: "Cuisine"),
        Device(id: "light.lampe_de_chevet", name: "Lampe de chevet", domain: "light", area: "Chambre"),
        Device(id: "light.lampe_du_bureau", name: "Lampe du bureau", domain: "light", area: "Bureau", on: true,
               brightness: 100),
        Device(id: "climate.thermostat", name: "Thermostat", domain: "climate", area: "Salon", on: true, target: 19,
               current: 19.5),
        Device(id: "cover.volet_du_salon", name: "Volet du salon", domain: "cover", area: "Salon", position: 100,
               deviceClass: "shutter"),
        Device(id: "cover.volet_de_la_chambre", name: "Volet de la chambre", domain: "cover", area: "Chambre",
               position: 0, deviceClass: "shutter"),
    ]

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items)?: items.compactMap(\.text)
        case .string(let text)?: [text]
        default: []
        }
    }

    /// The devices a call names, as Home Assistant's matching would find them (a little more forgiving: a name may
    /// also be an area's, as « le salon »).
    private struct Miss: Error {
        var why: String
        init(_ why: String) { self.why = why }
    }

    private func targets(_ a: [String: JSONValue], domains: Set<String>) -> Result<[Int], Miss> {
        let wanted = Set(Self.strings(a["domain"])).intersection(domains)
        let allowed = wanted.isEmpty ? domains : wanted
        var found = devices.indices.filter { allowed.contains(devices[$0].domain) }
        if let area = a["area"]?.text, !area.isEmpty {
            let key = Self.folded(area).replacingOccurrences(of: "^(le |la |les |l')", with: "", options: .regularExpression)
            guard devices.contains(where: { Self.folded($0.area) == key }) else { return .failure(Miss("No area named \(area)")) }
            found = found.filter { Self.folded(devices[$0].area) == key }
        }
        if let name = a["name"]?.text, !name.isEmpty {
            let key = Self.folded(name).replacingOccurrences(of: "^(le |la |les |l')", with: "", options: .regularExpression)
            let named = found.filter { Self.folded(devices[$0].name) == key || Self.folded(devices[$0].area) == key }
            guard !named.isEmpty else { return .failure(Miss("No device or entity named \(name)")) }
            found = named
        }
        guard !found.isEmpty else { return .failure(Miss("No device or entity matched")) }
        return .success(found)
    }

    private func done(_ indices: [Int], _ a: [String: JSONValue]) -> String {
        var success: [JSONValue] = []
        if let area = a["area"]?.text { success.append(["name": .string(area), "type": "area", "id": .string(Self.folded(area))]) }
        success += indices.map { ["name": .string(devices[$0].name), "type": "entity", "id": .string(devices[$0].id)] }
        let response: JSONValue = ["speech": [:], "response_type": "action_done",
                                   "data": ["targets": [], "success": .array(success), "failed": []]]
        return String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self)
    }

    private func call(_ name: String, _ a: [String: JSONValue]) -> (String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        func failed(_ why: String) -> (String, Bool) { ("Error calling tool: \(why)", true) }
        switch name {
        case "HassTurnOn", "HassTurnOff":
            let on = name == "HassTurnOn"
            switch targets(a, domains: ["light", "cover", "climate"]) {
            case .failure(let miss): return failed(miss.why)
            case .success(var found):
                if a["domain"] == nil, a["name"] == nil { found = found.filter { devices[$0].domain == "light" } }
                for i in found {
                    if devices[i].domain == "cover" { devices[i].position = on ? 100 : 0 } else { devices[i].on = on }
                }
                return (done(found, a), false)
            }
        case "HassLightSet":
            switch targets(a, domains: ["light"]) {
            case .failure(let miss): return failed(miss.why)
            case .success(let found):
                for i in found {
                    if let level = a["brightness"]?.integer {
                        devices[i].brightness = level
                        devices[i].on = level > 0
                    }
                }
                return (done(found, a), false)
            }
        case "HassClimateSetTemperature":
            guard let temperature = a["temperature"].flatMap({ $0.integer.map(Double.init) ?? Double($0.text ?? "") })
            else { return failed("required key not provided @ data['temperature']") }
            switch targets(a, domains: ["climate"]) {
            case .failure(let miss): return failed(miss.why)
            case .success(let found):
                for i in found { devices[i].target = temperature }
                return (done(found, a), false)
            }
        case "HassSetPosition":
            guard let position = a["position"]?.integer else { return failed("required key not provided @ data['position']") }
            switch targets(a, domains: ["cover"]) {
            case .failure(let miss): return failed(miss.why)
            case .success(let found):
                for i in found { devices[i].position = position }
                return (done(found, a), false)
            }
        case "GetLiveContext":
            var text = "Live Context: An overview of the areas and the devices in this smart home:"
            for d in devices {
                text += "\n- names: \(d.name)\n  domain: \(d.domain)\n  state: "
                switch d.domain {
                case "cover": text += (d.position ?? 0) > 0 ? "open" : "closed"
                case "climate": text += "heat"
                case "sensor": text += "'\(d.current ?? 0)'"
                default: text += d.on ? "'on'" : "'off'"
                }
                text += "\n  areas: \(d.area)"
                var attributes: [String] = []
                if let b = d.brightness, d.on { attributes.append("brightness: '\(b * 255 / 100)'") }
                if let t = d.target { attributes.append("temperature: '\(t)'") }
                if let c = d.current, d.domain == "climate" { attributes.append("current_temperature: '\(c)'") }
                if let p = d.position { attributes.append("current_position: '\(p)'") }
                if d.domain == "sensor" { attributes.append("unit_of_measurement: °C") }
                if !attributes.isEmpty { text += "\n  attributes:\n" + attributes.map { "    " + $0 }.joined(separator: "\n") }
            }
            let response: JSONValue = ["success": true, "result": .string(text)]
            return (String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self), false)
        case "GetDateTime":
            let response: JSONValue = ["success": true, "result": [
                "date": "2026-10-15", "time": "18:42:00", "timezone": "Europe/Paris", "weekday": "Thursday",
            ]]
            return (String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self), false)
        case "HassListAddItem", "HassListCompleteItem":
            guard a["item"]?.text != nil else { return failed("required key not provided @ data['item']") }
            let response: JSONValue = ["speech": [:], "response_type": "action_done",
                                       "data": ["targets": [], "success": [["name": "Liste de courses", "type": "entity",
                                                                            "id": "todo.liste_de_courses"]],
                                                "failed": []]]
            return (String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self), false)
        case "todo_get_items":
            let response: JSONValue = ["success": true, "result": [["summary": "Lait", "status": "needs_action"]]]
            return (String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self), false)
        default:
            return failed("Tool \"\(name)\" not found")
        }
    }

    // MARK: - The tools, as Home Assistant lists them

    private static let target: [String: JSONValue] = [
        "name": ["type": "string"], "area": ["type": "string"], "floor": ["type": "string"],
    ]
    private static let domain: JSONValue = ["type": "array", "items": ["type": "string"]]
    private static let deviceClass: JSONValue = ["type": "array", "items": ["type": "string", "enum": [
        "tv", "speaker", "receiver", "awning", "blind", "curtain", "damper", "door", "garage", "gate", "shade", "shutter",
        "window", "water", "gas", "outlet", "switch",
    ]]]

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                             required: [String] = []) -> JSONValue
    {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return ["name": .string(name), "description": .string(description), "inputSchema": .object(schema)]
    }

    /// What `tools/list` gives, in Home Assistant's order.
    public static let tools: [JSONValue] = [
        tool("HassTurnOn", "Turns on/opens/presses a device or entity. For locks, this performs a 'lock' action. Use for "
             + "requests like 'turn on', 'activate', 'enable', or 'lock'.",
             target.merging(["domain": domain, "device_class": deviceClass]) { a, _ in a }),
        tool("HassTurnOff", "Turns off/closes a device or entity. For locks, this performs an 'unlock' action. Use for "
             + "requests like 'turn off', 'deactivate', 'disable', or 'unlock'.",
             target.merging(["domain": domain, "device_class": deviceClass]) { a, _ in a }),
        tool("HassSetPosition", "Sets the position of a device or entity",
             target.merging(["domain": domain, "device_class": deviceClass,
                             "position": ["type": "integer", "minimum": 0, "maximum": 100]]) { a, _ in a },
             required: ["position"]),
        tool("HassListAddItem", "Add item to a todo list",
             ["item": ["type": "string"], "name": ["type": "string"]], required: ["item", "name"]),
        tool("HassListCompleteItem", "Complete item on a todo list",
             ["item": ["type": "string"], "name": ["type": "string"]], required: ["item", "name"]),
        tool("HassLightSet", "Sets the brightness percentage or color of a light",
             target.merging(["color": ["type": "string"], "temperature": ["type": "integer"],
                             "brightness": ["type": "integer", "minimum": 0, "maximum": 100]]) { a, _ in a }),
        tool("HassClimateSetTemperature", "Sets the target temperature of a climate device or entity",
             target.merging(["temperature": ["type": "number"]]) { a, _ in a }, required: ["temperature"]),
        tool("todo_get_items", "Query a to-do list to find out what items are on it. Use this to answer questions like "
             + "'What's on my task list?' or 'Read my grocery list'. Filters items by status (needs_action, completed, all).",
             ["todo_list": ["type": "string", "enum": ["Liste de courses"]],
              "status": ["type": "string", "enum": ["needs_action", "completed", "all"],
                         "description": "Filter returned items by status, by default returns incomplete items"]],
             required: ["todo_list"]),
        tool("GetDateTime", "Provides the current date and time.", [:]),
        tool("GetLiveContext", "Provides real-time information about the CURRENT state, value, or mode of devices, "
             + "sensors, entities, or areas. Use this tool for: 1. Answering questions about current conditions (e.g., "
             + "\"Is the light on?\"). 2. As the first step in conditional actions (e.g., \"If the weather is rainy, turn "
             + "off sprinklers\" requires checking the weather first).", [:]),
    ]
}
