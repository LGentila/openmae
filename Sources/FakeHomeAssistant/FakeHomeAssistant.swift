import Foundation
import Network
import VoiceCore

/// A pretend Home Assistant for the tests and the benchmarks: its MCP server (the "Model Context Protocol Server"
/// integration) on a local port, Streamable HTTP at `/api/mcp`, with the tools Home Assistant lists for its Assist API
/// over a small house: lights in four rooms, a thermostat, two covers, a speaker, a robot vacuum and a shopping list. It
/// lists them as a current Home Assistant does (`newerTools`: the integration before each name, titles, `readOnlyHint`),
/// or as older versions did (`olderTools`, with `Options.olderNames`). It changes its house as the calls ask and answers as
/// Home Assistant does (an intent's response as JSON text; `isError` and "Error calling tool: …" when nothing matches).
///
/// How it answers depends on `options`: JSON (Home Assistant's way) or a stream of server-sent events, with a session or
/// not, a token to check or not, the list in pages, no answer at all.
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
        /// Lists its tools as older versions of Home Assistant did (`olderTools`): without the integration before each
        /// name, without titles or annotations, only the lights', the thermostat's, the covers' and the list's.
        public var olderNames = false

        public init() {}
    }

    public struct Call: Sendable, Equatable {
        /// As the call named it: one of the names `tools/list` gave (`intent__HassTurnOn`, or `HassTurnOn` with
        /// `Options.olderNames`).
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
        /// On, open, playing or cleaning.
        var on = false
        var brightness: Int?
        var target: Double?
        var current: Double?
        var position: Int?
        var deviceClass: String?
        var volume: Int?
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
    public private(set) var port: UInt16 = 0

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
        return Request(method: String(parts[0]), path: String(parts[1].prefix { $0 != "?" }), headers: headers,
                       body: Data(body.prefix(length)))
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
        guard request.path == "/api/mcp" else { return Response(status: 404, body: Data("404: Not Found".utf8), type: "text/plain") }
        guard request.method == "POST" else { return Response(status: 405, type: "text/plain") }
        if let token = options.token, request.headers["authorization"] != "Bearer \(token)" {
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
        let tools = Self.tools(olderNames: options.olderNames)
        let reply: JSONValue
        switch method {
        case "initialize":
            reply = ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
                "serverInfo": ["name": "home-assistant", "version": "2026.10.0"],
            ]]
        case "tools/list":
            let start = params["cursor"]?.text.flatMap { Int($0) } ?? 0
            let end = min(tools.count, start + (options.pageSize ?? tools.count))
            var result: [String: JSONValue] = ["tools": .array(Array(tools[start..<end]))]
            if end < tools.count { result["nextCursor"] = .string(String(end)) }
            reply = ["jsonrpc": "2.0", "id": id, "result": .object(result)]
        case "tools/call":
            let name = params["name"]?.text ?? ""
            let arguments: [String: JSONValue] = if case .object(let a)? = params["arguments"] { a } else { [:] }
            lock.withLock { made.append(Call(name: name, arguments: arguments)) }
            // Only a name it listed: `HassTurnOn` is no tool of a Home Assistant that lists `intent__HassTurnOn`.
            let listed = tools.contains { if case .object(let tool) = $0 { tool["name"]?.text == name } else { false } }
            let (text, isError) = listed ? call(ConnectedTools.homeAssistantName(name), arguments)
                : ("Error calling tool: Tool \"\(name)\" not found", true)
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
        Device(id: "media_player.enceinte_du_salon", name: "Enceinte du salon", domain: "media_player", area: "Salon",
               deviceClass: "speaker", volume: 30),
        Device(id: "vacuum.robot_aspirateur", name: "Robot aspirateur", domain: "vacuum", area: "Cuisine"),
    ]

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// A name or a room as the user says it, without its article: « le salon » → salon.
    private static func key(_ text: String) -> String {
        folded(text).replacingOccurrences(of: "^(le |la |les |l')", with: "", options: .regularExpression)
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
            let key = Self.key(area)
            guard devices.contains(where: { Self.folded($0.area) == key }) else { return .failure(Miss("No area named \(area)")) }
            found = found.filter { Self.folded(devices[$0].area) == key }
        }
        if let name = a["name"]?.text, !name.isEmpty {
            let key = Self.key(name)
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
        return Self.text(response)
    }

    private static func text(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }

    /// A call, by Home Assistant's own name for the tool (`ConnectedTools.homeAssistantName`: `HassTurnOn`,
    /// `GetLiveContext`, `todo_get_items`), whichever names it lists.
    private func call(_ name: String, _ a: [String: JSONValue]) -> (String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        func failed(_ why: String) -> (String, Bool) { ("Error calling tool: \(why)", true) }
        /// Each device the call names (its targets in `targets`), of these domains, changed as `change` says.
        func act(on domains: Set<String>, targets named: [String: JSONValue]? = nil, _ change: (inout Device) -> Void)
            -> (String, Bool)
        {
            let named = named ?? a
            switch targets(named, domains: domains) {
            case .failure(let miss): return failed(miss.why)
            case .success(let found):
                for i in found { change(&devices[i]) }
                return (done(found, named), false)
            }
        }
        switch name {
        case "HassTurnOn", "HassTurnOff":
            let on = name == "HassTurnOn"
            switch targets(a, domains: ["light", "cover", "climate", "media_player"]) {
            case .failure(let miss): return failed(miss.why)
            case .success(var found):
                if a["domain"] == nil, a["name"] == nil { found = found.filter { devices[$0].domain == "light" } }
                for i in found {
                    if devices[i].domain == "cover" { devices[i].position = on ? 100 : 0 } else { devices[i].on = on }
                }
                return (done(found, a), false)
            }
        case "HassLightSet":
            return act(on: ["light"]) { device in
                if let level = a["brightness"]?.integer {
                    device.brightness = level
                    device.on = level > 0
                }
            }
        case "HassClimateSetTemperature":
            guard let temperature = a["temperature"].flatMap({ $0.integer.map(Double.init) ?? Double($0.text ?? "") })
            else { return failed("required key not provided @ data['temperature']") }
            return act(on: ["climate"]) { $0.target = temperature }
        case "HassSetPosition":
            guard let position = a["position"]?.integer else { return failed("required key not provided @ data['position']") }
            return act(on: ["cover"]) { $0.position = position }
        case "HassMediaPause", "HassMediaUnpause":
            let playing = name == "HassMediaUnpause"
            return act(on: ["media_player"]) { $0.on = playing }
        case "HassMediaNext", "HassMediaPrevious", "HassMediaPlayerMute", "HassMediaPlayerUnmute":
            return act(on: ["media_player"]) { _ in }
        case "HassSetVolume":
            guard let level = a["volume_level"]?.integer else { return failed("required key not provided @ data['volume_level']") }
            return act(on: ["media_player"]) { $0.volume = level }
        case "HassSetVolumeRelative":
            guard let step = a["volume_step"] else { return failed("required key not provided @ data['volume_step']") }
            let change = step.integer ?? (step.text == "down" ? -10 : 10)
            return act(on: ["media_player"]) { $0.volume = min(100, max(0, ($0.volume ?? 50) + change)) }
        case "search_media":
            guard let query = a["search_query"]?.text else { return failed("required key not provided @ data['search_query']") }
            let response: JSONValue = ["success": true, "result": [[
                "title": .string(query), "media_class": "track", "media_content_id": "media-source://fake/1",
                "media_content_type": "music",
            ]]]
            return (Self.text(response), false)
        case "play_media":
            guard a["media_content_id"] != nil, a["media_content_type"] != nil else {
                return failed("required key not provided @ data['media_content_id']")
            }
            var player: [String: JSONValue] = [:]
            for key in ["name", "area", "floor"] { player[key] = a["player_\(key)"] }
            return act(on: ["media_player"], targets: player) { $0.on = true }
        case "HassVacuumStart", "HassVacuumReturnToBase":
            let cleaning = name == "HassVacuumStart"
            return act(on: ["vacuum"]) { $0.on = cleaning }
        case "HassVacuumCleanArea":
            guard let area = a["area"]?.text else { return failed("required key not provided @ data['area']") }
            guard devices.contains(where: { Self.folded($0.area) == Self.key(area) }) else { return failed("No area named \(area)") }
            guard let i = devices.firstIndex(where: { $0.domain == "vacuum" }) else { return failed("No device or entity matched") }
            devices[i].on = true
            return (done([i], [:]), false)
        case "HassBroadcast":
            guard a["message"]?.text != nil else { return failed("required key not provided @ data['message']") }
            return (done([], [:]), false)
        case "HassCancelAllTimers":
            return (done([], [:]), false)
        case "GetLiveContext":
            // Newer versions filter by area, domain (one or a list) and name, as Home Assistant matches them: a name is a
            // device's (not a room's); nothing found is an error.
            var shown = devices
            if let area = a["area"]?.text, !area.isEmpty {
                guard devices.contains(where: { Self.folded($0.area) == Self.key(area) }) else {
                    return failed("Area '\(area)' does not exist")
                }
                shown = shown.filter { Self.folded($0.area) == Self.key(area) }
            }
            let domains = Set(Self.strings(a["domain"]).map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
            if !domains.isEmpty {
                shown = shown.filter { domains.contains($0.domain) }
                guard !shown.isEmpty else {
                    return failed("No exposed entities found in domain(s): \(domains.sorted().joined(separator: ", "))")
                }
            }
            if let name = a["name"]?.text, !name.isEmpty {
                shown = shown.filter { Self.folded($0.name) == Self.key(name) }
                guard !shown.isEmpty else { return failed("No exposed entities matched name '\(name)'") }
            }
            var text = "Live Context: An overview of the areas and the devices in this smart home:"
            for d in shown {
                text += "\n- names: \(d.name)\n  domain: \(d.domain)\n  state: "
                switch d.domain {
                case "cover": text += (d.position ?? 0) > 0 ? "open" : "closed"
                case "climate": text += "heat"
                case "sensor": text += "'\(d.current ?? 0)'"
                case "media_player": text += d.on ? "playing" : "paused"
                case "vacuum": text += d.on ? "cleaning" : "docked"
                default: text += d.on ? "'on'" : "'off'"
                }
                text += "\n  areas: \(d.area)"
                var attributes: [String] = []
                if let b = d.brightness, d.on { attributes.append("brightness: '\(b * 255 / 100)'") }
                if let t = d.target { attributes.append("temperature: '\(t)'") }
                if let c = d.current, d.domain == "climate" { attributes.append("current_temperature: '\(c)'") }
                if let p = d.position { attributes.append("current_position: '\(p)'") }
                if let v = d.volume { attributes.append("volume_level: '\(Double(v) / 100)'") }
                if d.domain == "sensor" { attributes.append("unit_of_measurement: °C") }
                if !attributes.isEmpty { text += "\n  attributes:\n" + attributes.map { "    " + $0 }.joined(separator: "\n") }
            }
            return (Self.text(["success": true, "result": .string(text)]), false)
        case "GetDateTime":
            return (Self.text(["success": true, "result": [
                "date": "2026-10-15", "time": "18:42:00", "timezone": "Europe/Paris", "weekday": "Thursday",
            ]]), false)
        case "HassListAddItem", "HassListCompleteItem", "HassListRemoveItem":
            guard a["item"]?.text != nil else { return failed("required key not provided @ data['item']") }
            return (Self.text(["speech": [:], "response_type": "action_done",
                               "data": ["targets": [], "success": [["name": "Liste de courses", "type": "entity",
                                                                    "id": "todo.liste_de_courses"]],
                                        "failed": []]]), false)
        case "todo_get_items":
            return (Self.text(["success": true, "result": [["summary": "Lait", "status": "needs_action"]]]), false)
        default:
            return failed("Tool \"\(name)\" not found")
        }
    }

    // MARK: - The tools, as Home Assistant lists them

    /// What `tools/list` gives, in Home Assistant's order.
    public static func tools(olderNames: Bool = false) -> [JSONValue] { olderNames ? olderTools : newerTools }

    /// A list of these strings, as a schema.
    private static func list(_ values: [String]) -> JSONValue {
        ["type": "array", "items": ["type": "string", "enum": .array(values.map { .string($0) })]]
    }

    private static let string: JSONValue = ["type": "string"]
    /// An intent's targets.
    private static let target: [String: JSONValue] = ["name": string, "area": string, "floor": string]

    /// A tool as a current Home Assistant lists it: its integration before its name, a title, whether it only reads
    /// (`readOnlyHint`, the one annotation the app reads), a `required` list only when there is one.
    private static func newer(_ name: String, _ title: String, _ description: String, _ properties: [String: JSONValue],
                              required: [String] = [], reads: Bool = false) -> JSONValue
    {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return ["name": .string(name), "title": .string(title), "description": .string(description),
                "inputSchema": .object(schema), "annotations": ["readOnlyHint": .bool(reads)]]
    }

    private static let onOffClasses = list([
        "identify", "restart", "update", "awning", "blind", "curtain", "damper", "door", "garage", "gate", "shade", "shutter",
        "window", "tv", "speaker", "receiver", "projector", "outlet", "switch", "water", "gas",
    ])
    private static let coverClasses = list([
        "awning", "blind", "curtain", "damper", "door", "garage", "gate", "shade", "shutter", "window", "water", "gas",
    ])
    /// A media player's intent: its targets, as a speaker, a TV… of the media_player domain.
    private static let player = target.merging([
        "device_class": list(["tv", "speaker", "receiver", "projector"]), "domain": list(["media_player"]),
    ]) { a, _ in a }
    private static let muted: JSONValue = ["description": "Whether the media player should be muted or unmuted"]
    private static let vacuum = target.merging(["domain": list(["vacuum"])]) { a, _ in a }
    private static let item: [String: JSONValue] = ["item": string, "name": string]

    /// As the user's Home Assistant listed them on 2026-10-27 (the same 24 names, descriptions, schemas, titles and
    /// `readOnlyHint`; the pretend house's list in `todo_list`), with the thermostat's and the covers' two, which a Home
    /// Assistant lists when it exposes one (`climate__HassClimateSetTemperature`, `intent__HassSetPosition`: their
    /// descriptions and schemas from Home Assistant's source, their titles written as the others').
    public static let newerTools: [JSONValue] = [
        newer("assist_satellite__HassBroadcast", "Broadcast message", "Broadcast a message through the home",
              ["message": string], required: ["message"]),
        newer("climate__HassClimateSetTemperature", "Set temperature",
              "Sets the target temperature of a climate device or entity",
              target.merging(["temperature": ["type": "number"]]) { a, _ in a }, required: ["temperature"]),
        newer("homeassistant__GetLiveContext", "Get live context",
              "Provides real-time information about the CURRENT state, value, or mode of devices, sensors, entities, or "
                  + "areas. Use this tool for: 1. Answering questions about current conditions (e.g., 'Is the light on?'). "
                  + "2. As the first step in conditional actions (e.g., 'If the weather is rainy, turn off sprinklers' "
                  + "requires checking the weather first). You may filter for devices by name, domain, and area, including "
                  + "combining those filters. Prefer filtering by domain when searching for multiple devices of the same type.",
              ["domain": ["description": "Filter entities by domain (e.g. 'light', 'sensor'). Accepts a single domain or a list.",
                          "anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]],
               "area": ["type": "string", "description": "Filter entities by area name or alias (case-insensitive)."],
               "name": ["type": "string", "description": "Filter entities by name or alias (case-insensitive)."]],
              reads: true),
        newer("intent__HassTurnOn", "Turn on",
              "Turns on/opens/presses a device or entity. For locks, this performs a 'lock' action. Use for requests like "
                  + "'turn on', 'activate', 'enable', or 'lock'.",
              target.merging(["domain": ["type": "array", "items": ["type": "string"]], "device_class": onOffClasses]) { a, _ in a }),
        newer("intent__HassTurnOff", "Turn off",
              "Turns off/closes a device or entity. For locks, this performs an 'unlock' action. Use for requests like "
                  + "'turn off', 'deactivate', 'disable', or 'unlock'.",
              target.merging(["domain": ["type": "array", "items": ["type": "string"]], "device_class": onOffClasses]) { a, _ in a }),
        newer("intent__HassSetPosition", "Set position", "Sets the position of a device or entity",
              target.merging(["domain": ["type": "array", "items": ["type": "string"]], "device_class": coverClasses,
                              "position": ["type": "integer", "minimum": 0, "maximum": 100]]) { a, _ in a },
              required: ["position"]),
        newer("intent__HassCancelAllTimers", "Cancel all timers", "Cancels all timers", ["area": string]),
        newer("light__HassLightSet", "Set light", "Sets the brightness percentage or color of a light",
              target.merging([
                  "brightness": ["type": "integer", "minimum": 0, "maximum": 100, "description":
                      "The brightness percentage of the light between 0 and 100, where 0 is off and 100 is fully lit"],
                  "temperature": ["type": "integer", "minimum": 0], "color": string, "domain": list(["light"]),
              ]) { a, _ in a }),
        newer("llm__GetDateTime", "Get date and time", "Provides the current date and time.", [:], reads: true),
        newer("media_player__HassMediaUnpause", "Resume media", "Resumes a media player", player),
        newer("media_player__HassMediaPause", "Pause media", "Pauses a media player", player),
        newer("media_player__HassMediaNext", "Next track", "Skips a media player to the next item", player),
        newer("media_player__HassMediaPrevious", "Previous track", "Replays the previous item for a media player", player),
        newer("media_player__HassSetVolume", "Set volume", "Sets the volume percentage of a media player",
              player.merging(["volume_level": ["type": "integer", "minimum": 0, "maximum": 100,
                                               "description": "The volume percentage of the media player"]]) { a, _ in a },
              required: ["volume_level"]),
        newer("media_player__HassSetVolumeRelative", "Change volume", "Increases or decreases the volume of a media player",
              target.merging(["volume_step": ["anyOf": [["type": "string", "enum": ["up", "down"]],
                                                        ["type": "integer", "minimum": -100, "maximum": 100]]]]) { a, _ in a },
              required: ["volume_step"]),
        newer("media_player__HassMediaPlayerMute", "Mute player", "Mutes a media player",
              player.merging(["is_volume_muted": muted]) { a, _ in a }),
        newer("media_player__HassMediaPlayerUnmute", "Unmute player", "Unmutes a media player",
              player.merging(["is_volume_muted": muted]) { a, _ in a }),
        newer("media_player__search_media", "Search media",
              "Searches a media player for media. Can also search inside a result of an earlier search, such as an artist "
                  + "or an album.",
              ["search_query": ["type": "string", "description": "What to search for, such as a song, artist or album"],
               "within_media_content_id": ["type": "string", "description":
                   "The media_content_id of a result to search inside, such as an artist. Copy it from that result."],
               "within_media_content_type": ["type": "string", "description":
                   "The media_content_type of the result to search inside. Copy it from that result."],
               "player_name": string, "player_area": string, "player_floor": string],
              required: ["search_query"], reads: true),
        newer("media_player__play_media", "Play media",
              "Plays a media item that the search media tool returned, or a URL. For a search result, pass the same "
                  + "player_name, player_area and player_floor as the search.",
              ["media_content_id": ["type": "string", "description": "The media_content_id of the search result, or a URL"],
               "media_content_type": ["type": "string", "description":
                   "The media_content_type of the search result. Use music to play an audio URL."],
               "player_name": string, "player_area": string, "player_floor": string],
              required: ["media_content_id", "media_content_type"]),
        newer("todo__get_items", "Get to-do list items",
              "Query a to-do list to find out what items are on it. Use this to answer questions like 'What's on my task "
                  + "list?' or 'Read my grocery list'. Filters items by status (needs_action, completed, all).",
              ["todo_list": ["type": "string", "enum": ["Liste de courses"]],
               "status": ["type": "string", "enum": ["needs_action", "completed", "all"], "default": "needs_action",
                          "description": "Filter returned items by status, by default returns incomplete items"]],
              required: ["todo_list"], reads: true),
        newer("todo__HassListAddItem", "Add to-do list item", "Add item to a todo list", item, required: ["item", "name"]),
        newer("todo__HassListCompleteItem", "Complete to-do list item", "Complete item on a todo list", item,
              required: ["item", "name"]),
        newer("todo__HassListRemoveItem", "Remove to-do list item", "Remove one or more items from a todo list", item,
              required: ["item", "name"]),
        newer("vacuum__HassVacuumStart", "Start vacuum", "Starts a vacuum", vacuum),
        newer("vacuum__HassVacuumReturnToBase", "Return vacuum to base", "Returns a vacuum to base", vacuum),
        newer("vacuum__HassVacuumCleanArea", "Clean area", "Tells a vacuum to clean a specific area",
              ["area": string, "name": string], required: ["area"]),
    ]

    private static let olderClasses = list([
        "tv", "speaker", "receiver", "awning", "blind", "curtain", "damper", "door", "garage", "gate", "shade", "shutter",
        "window", "water", "gas", "outlet", "switch",
    ])

    private static func older(_ name: String, _ description: String, _ properties: [String: JSONValue],
                              required: [String] = []) -> JSONValue
    {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return ["name": .string(name), "description": .string(description), "inputSchema": .object(schema)]
    }

    /// As older versions of Home Assistant list them (without the integration before the names, without titles or
    /// annotations), for the lights, the thermostat, the covers and the list: the pretend Home Assistant's tools before
    /// it listed the newer ones.
    public static let olderTools: [JSONValue] = [
        older("HassTurnOn", "Turns on/opens/presses a device or entity. For locks, this performs a 'lock' action. Use for "
              + "requests like 'turn on', 'activate', 'enable', or 'lock'.",
              target.merging(["domain": ["type": "array", "items": ["type": "string"]], "device_class": olderClasses]) { a, _ in a }),
        older("HassTurnOff", "Turns off/closes a device or entity. For locks, this performs an 'unlock' action. Use for "
              + "requests like 'turn off', 'deactivate', 'disable', or 'unlock'.",
              target.merging(["domain": ["type": "array", "items": ["type": "string"]], "device_class": olderClasses]) { a, _ in a }),
        older("HassSetPosition", "Sets the position of a device or entity",
              target.merging(["domain": ["type": "array", "items": ["type": "string"]], "device_class": olderClasses,
                              "position": ["type": "integer", "minimum": 0, "maximum": 100]]) { a, _ in a },
              required: ["position"]),
        older("HassListAddItem", "Add item to a todo list", item, required: ["item", "name"]),
        older("HassListCompleteItem", "Complete item on a todo list", item, required: ["item", "name"]),
        older("HassLightSet", "Sets the brightness percentage or color of a light",
              target.merging(["color": string, "temperature": ["type": "integer"],
                              "brightness": ["type": "integer", "minimum": 0, "maximum": 100]]) { a, _ in a }),
        older("HassClimateSetTemperature", "Sets the target temperature of a climate device or entity",
              target.merging(["temperature": ["type": "number"]]) { a, _ in a }, required: ["temperature"]),
        older("todo_get_items", "Query a to-do list to find out what items are on it. Use this to answer questions like "
              + "'What's on my task list?' or 'Read my grocery list'. Filters items by status (needs_action, completed, all).",
              ["todo_list": ["type": "string", "enum": ["Liste de courses"]],
               "status": ["type": "string", "enum": ["needs_action", "completed", "all"],
                          "description": "Filter returned items by status, by default returns incomplete items"]],
              required: ["todo_list"]),
        older("GetDateTime", "Provides the current date and time.", [:]),
        older("GetLiveContext", "Provides real-time information about the CURRENT state, value, or mode of devices, "
              + "sensors, entities, or areas. Use this tool for: 1. Answering questions about current conditions (e.g., "
              + "\"Is the light on?\"). 2. As the first step in conditional actions (e.g., \"If the weather is rainy, turn "
              + "off sprinklers\" requires checking the weather first).", [:]),
    ]
}
