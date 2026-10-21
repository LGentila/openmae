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
