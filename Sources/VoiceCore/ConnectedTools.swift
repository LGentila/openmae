import Foundation

// Connected tools (MCP): services the user adds by their address (Home Assistant, …), whose tools become actions Maé
// can call next to the built-in ones. The list of a tool's actions is fetched when it is added, tested or reconnected,
// and kept with the settings, so the system prompt stays the same from one launch to the next. Their tokens are in the
// keychain, never here.

/// A connected tool, as the settings keep it.
public struct ConnectedToolSettings: Sendable, Codable, Equatable, Identifiable {
    /// How the app proves it may use the service.
    public enum Access: String, Sendable, Codable, CaseIterable {
        /// A token the user pasted (Home Assistant's long-lived access token), sent as `Authorization: Bearer`.
        case token
        /// Nothing is sent.
        case none
        /// Signing in with the user's account (OAuth): not built yet.
        case account
    }

    /// What Maé does before an action that changes something.
    public enum WhenActing: String, Sendable, Codable {
        /// She says what she is about to do and waits for the user's "oui" (the default).
        case askFirst
        case doDirectly
    }

    /// One of its actions, as the service listed it, and whether Maé may use it.
    public struct Action: Sendable, Codable, Equatable {
        public var tool: MCPTool
        public var enabled: Bool

        public init(tool: MCPTool, enabled: Bool) {
            self.tool = tool
            self.enabled = enabled
        }

        public var name: String { tool.name }
        /// It only reads: it never waits for a "oui".
        public var reads: Bool { ConnectedTools.reads(tool) }
    }

    public var id: UUID
    /// The user's name for it: "Home Assistant".
    public var name: String
    /// As typed: "http://homeassistant.local:8123/api/mcp".
    public var address: String
    public var access: Access
    public var enabled = true
    public var whenActing = WhenActing.askFirst
    public var actions: [Action] = []

    public init(id: UUID = UUID(), name: String, address: String, access: Access, enabled: Bool = true,
                whenActing: WhenActing = .askFirst, actions: [Action] = [])
    {
        self.id = id
        self.name = name
        self.address = address
        self.access = access
        self.enabled = enabled
        self.whenActing = whenActing
        self.actions = actions
    }

    /// The actions a new list gives, keeping the switches of those already known; a new one is on, unless Maé has a
    /// built-in action for it (`ConnectedTools.duplicatesBuiltIn`).
    public func merging(_ tools: [MCPTool]) -> [Action] {
        tools.map { tool in
            Action(tool: tool, enabled: actions.first { $0.name == tool.name }?.enabled
                ?? !ConnectedTools.duplicatesBuiltIn(tool.name))
        }
    }
}

/// Where a connected tool stands, for the settings.
public enum ConnectedToolState: String, Sendable, Codable, Equatable {
    case connected
    /// It refused the access (401, 403): a new token is needed.
    case needsReconnect
    case unreachable
}

/// Why an action of a connected tool failed, for its log.
public enum ConnectedToolFailure: Sendable, Codable, Equatable {
    case noAnswer
    case unreachable
    case unauthorized
    /// The service, or the tool, said why.
    case said(String)

    init(_ error: MCPError) {
        switch error {
        case .noAnswer: self = .noAnswer
        case .unreachable: self = .unreachable
        case .unauthorized: self = .unauthorized
        case .notMCP(let what): self = .said(what)
        case .refused(let message): self = .said(message)
        }
    }
}

/// One line of a connected tool's log.
public struct ConnectedToolLogEntry: Sendable, Codable, Equatable {
    public enum Result: Sendable, Codable, Equatable {
        case done
        case refusedByUser
        case failed(ConnectedToolFailure)
    }

    public var date: Date
    /// What was done, in French like what Maé says: "Allumer le salon".
    public var title: String
    public var result: Result

    public init(date: Date, title: String, result: Result) {
        self.date = date
        self.title = title
        self.result = result
    }
}

/// What the settings' "Test" button (or adding a tool) found.
public enum ConnectedToolTest: Sendable, Codable, Equatable {
    case works(tools: [MCPTool], seconds: Double)
    case failed(MCPError)
}

/// What the connected tools tell the interface, as it happens.
public enum ConnectedToolReport: Sendable, Equatable {
    case log(UUID, ConnectedToolLogEntry)
    case state(UUID, ConnectedToolState)
    /// The service said its list of tools changed: it is fetched again (applies at the next conversation).
    case toolsChanged(UUID)
}

/// The connected tools that are on, as a `ToolProvider`: each one's enabled actions.
public actor ConnectedTools: ToolProvider {
    /// A tool that is on, with what reaches it.
    public struct Connection: Sendable {
        public var settings: ConnectedToolSettings
        public var client: MCPClient

        public init(settings: ConnectedToolSettings, client: MCPClient) {
            self.settings = settings
            self.client = client
        }
    }

    /// Longest text of a result the model reads: Home Assistant's `GetLiveContext` lists every device it exposes.
    public static let resultLimit = 3000

    public nonisolated let identifier = "connected-tools"
    private var connections: [Connection] = []
    private var specs: [ToolSpec] = []
    private var addendum: String?
    /// The name the model sees → the connection and the service's tool.
    private var offered: [String: (connection: Int, tool: MCPTool)] = [:]
    private var report: @Sendable (ConnectedToolReport) -> Void = { _ in }

    public init() {}

    /// Where the log lines and the states go.
    public func observe(_ report: @escaping @Sendable (ConnectedToolReport) -> Void) {
        self.report = report
    }

    /// The tools that are on. Returns true when what the model sees changed (the tools, their descriptions, the prompt's
    /// part), or how it is handled (a risk).
    @discardableResult
    public func configure(_ connections: [Connection]) -> Bool {
        let before = (specs, addendum)
        self.connections = connections.filter(\.settings.enabled)
        var specs: [ToolSpec] = []
        var offered: [String: (connection: Int, tool: MCPTool)] = [:]
        var taken = Self.builtInNames
        for (index, connection) in self.connections.enumerated() {
            for action in connection.settings.actions where action.enabled {
                var name = action.name
                var n = 2
                while taken.contains(name) {
                    name = "\(action.name)_\(n)"
                    n += 1
                }
                taken.insert(name)
                offered[name] = (index, action.tool)
                let risk: ToolRisk = action.reads ? .read
                    : connection.settings.whenActing == .askFirst ? .sensitive : .undoable
                specs.append(ToolSpec(name: name, description: Self.description(action.tool),
                                      parameters: Self.parameters(action.tool), risk: risk))
            }
        }
        self.specs = specs
        self.offered = offered
        addendum = specs.isEmpty ? nil : Self.promptAddendum(self.connections.filter { c in
            c.settings.actions.contains(where: \.enabled)
        }.map(\.settings.name))
        return before.0 != specs || before.1 != addendum
    }

    // `async` like the protocol's defaults: a synchronous version would lose to them in async callers.
    public func tools() async -> [ToolSpec] { specs }

    public func promptAddendum() async -> String? { addendum }

    public func risk(of call: ToolCall) async -> ToolRisk {
        specs.first { $0.name == call.name }?.risk ?? .sensitive
    }

    public func summary(of call: ToolCall, context: ToolContext) async -> String {
        guard let (connection, tool) = lookup(call) else { return call.name }
        return ConnectedToolPhrases.confirm(tool, call.arguments, toolName: connection.settings.name)
    }

    public func declined(_ call: ToolCall) async {
        guard let (connection, tool) = lookup(call) else { return }
        report(.log(connection.settings.id, ConnectedToolLogEntry(
            date: Date(), title: ConnectedToolPhrases.title(tool, call.arguments), result: .refusedByUser)))
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        guard let (connection, tool) = lookup(call) else {
            throw ToolRefusal(forModel: "Outil inconnu.", spoken: ActionPhrases.notUnderstood(context.language))
        }
        let id = connection.settings.id
        let name = connection.settings.name
        let title = ConnectedToolPhrases.title(tool, call.arguments)
        let cannotUndo = ConnectedToolPhrases.cannotUndo(name)
        do {
            let result = try await connection.client.call(tool.name, arguments: call.arguments)
            report(.state(id, .connected))
            report(.log(id, ConnectedToolLogEntry(
                date: Date(), title: title,
                result: result.isError ? .failed(.said(Self.firstLine(result.text))) : .done)))
            if await connection.client.toolsChanged { report(.toolsChanged(id)) }
            let text = Self.capped(result.text)
            let forModel: JSONValue = result.isError
                ? ["échec": .string(text.isEmpty ? "\(name) n'a pas pu le faire." : text)]
                : ["résultat": Self.readable(text)]
            return ToolOutcome(spoken: result.isError ? ConnectedToolPhrases.failed(name) : ConnectedToolPhrases.done,
                               forModel: forModel, cannotUndo: cannotUndo, modelSpeaks: true)
        } catch let error as MCPError {
            let state: ConnectedToolState = switch error {
            case .unauthorized: .needsReconnect
            case .unreachable, .noAnswer: .unreachable
            case .notMCP, .refused: .connected  // it answered
            }
            report(.state(id, state))
            report(.log(id, ConnectedToolLogEntry(date: Date(), title: title, result: .failed(ConnectedToolFailure(error)))))
            throw ToolRefusal(forModel: ConnectedToolPhrases.errorForModel(error, name),
                              spoken: ConnectedToolPhrases.unavailable(error, name), retryable: false)
        }
    }

    private func lookup(_ call: ToolCall) -> (Connection, MCPTool)? {
        guard let (index, tool) = offered[call.name], connections.indices.contains(index) else { return nil }
        return (connections[index], tool)
    }

    // MARK: - What the model sees

    /// The names of the built-in tools, which a connected tool's never takes (`ToolRunner.tools()` keeps the first of two
    /// equal names).
    static var builtInNames: Set<String> {
        Set((ActionCatalog.calendarTools(movingItems: true) + [ActionCatalog.timer, WebSearchCatalog.search, NewsCatalog.read])
            .map(\.name))
            .union(ActionCatalog.runShortcut(names: ["x"]).map { [$0.name] } ?? []).union(AgentCatalog.names)
            .union(BuiltInSources.names).union([MemoryCatalog.name])
    }

    /// A few sentences for the system prompt: these tools are the user's, how to call them. Without the actions, the
    /// prompt has nothing else about calling a tool.
    static func promptAddendum(_ names: [String]) -> String {
        let list = names.map { "« \($0) »" }.joined(separator: ", ")
        return "L'utilisateur t'a connecté à \(list) : leurs outils agissent pour lui (allumer, éteindre, régler…) ou "
            + "lisent l'état de ce qu'ils pilotent. Quand il te demande d'agir avec eux, ou te pose une question sur ce "
            + "qu'ils pilotent, appelle l'outil directement, sans rien dire avant : l'app lui demande son accord quand il "
            + "le faut, puis te donne le résultat à lui dire. Ne dis jamais que c'est fait sans avoir appelé l'outil."
    }

    /// The service's description, as it wrote it; its title first when it has one and the description does not start
    /// with it.
    static func description(_ tool: MCPTool) -> String {
        let text = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = tool.title, !title.isEmpty, !text.lowercased().hasPrefix(title.lowercased()) else {
            return text.isEmpty ? tool.title ?? tool.name : text
        }
        return text.isEmpty ? title : "\(title). \(text)"
    }

    /// The parameters of a tool as the model sees them. Home Assistant's intents (`Hass…`) describe none of theirs, and
    /// the models misread them (in `voice-cli actions-bench` with Tests/Fixtures/home-assistant-fr.json, a room written
    /// as a `domain`, « light » as a `device_class`, which Home Assistant refuses): their targets get a line each, and
    /// their `device_class`, which a cover or a light never needs (their name, room or `domain` find them), is left out.
    static func parameters(_ tool: MCPTool) -> [ToolParameter] {
        let parameters = parameters(tool.inputSchema)
        guard tool.name.hasPrefix("Hass") else { return parameters }
        return parameters.filter { $0.name != "device_class" }.map { parameter in
            guard parameter.description.isEmpty, let line = homeAssistantTargets[parameter.name] else { return parameter }
            var described = parameter
            described.description = line
            return described
        }
    }

    /// What Home Assistant's targets are, as its intents use them.
    static let homeAssistantTargets = [
        "name": "The name of one device or entity, as the user says it (not a room)",
        "area": "The room (area) the user names, as they say it: salon, cuisine…",
        "floor": "The floor the user names",
        "domain": "Only when the user names a kind of device for all of them or for a whole room: light, switch, cover, "
            + "climate, fan, lock or media_player",
    ]

    /// The parameters of a JSON Schema object, by name (a stable order, so that the prompt does not change): strings,
    /// numbers, booleans, one value among some and lists of strings as such; anything deeper passed on as written.
    static func parameters(_ schema: JSONValue) -> [ToolParameter] {
        guard case .object(let object) = schema, case .object(let properties)? = object["properties"] else { return [] }
        var required: Set<String> = []
        if case .array(let names)? = object["required"] { required = Set(names.compactMap(\.text)) }
        return properties.keys.sorted().map { name in
            let property = properties[name] ?? .object([:])
            var description = ""
            if case .object(let p) = property {
                description = p["description"]?.text ?? ""
                if let low = p["minimum"]?.text, let high = p["maximum"]?.text {
                    description += (description.isEmpty ? "" : " ") + "(\(low) to \(high))"
                }
            }
            return ToolParameter(name, kind(property), description, required: required.contains(name))
        }
    }

    static func kind(_ property: JSONValue) -> ToolParameter.Kind {
        guard case .object(let p) = property else { return .schema(property) }
        let type: String? = switch p["type"] {
        case .string(let type): type
        case .array(let types): types.compactMap(\.text).first { $0 != "null" }
        default: nil
        }
        let values: [String] = if case .array(let items)? = p["enum"] { items.compactMap(\.text) } else { [] }
        guard p["anyOf"] == nil, p["oneOf"] == nil, p["allOf"] == nil else { return .schema(property) }
        switch type {
        case "string": return values.isEmpty ? .string : .oneOf(values)
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array":
            guard case .object(let items)? = p["items"], items["type"]?.text == "string", items["anyOf"] == nil else {
                return .schema(property)
            }
            let allowed: [String] = if case .array(let v)? = items["enum"] { v.compactMap(\.text) } else { [] }
            return .strings(allowed)
        case nil where !values.isEmpty: return .oneOf(values)
        default: return .schema(property)
        }
    }

    // MARK: - What is safe

    /// The reading tools of Home Assistant, which older versions list without annotations.
    static let homeAssistantReads: Set<String> = ["GetLiveContext", "GetDateTime", "todo_get_items", "calendar_get_events",
                                                  "HassGetState", "HassGetWeather", "HassGetCurrentDate",
                                                  "HassGetCurrentTime"]

    /// A tool that only reads: the service says so (`readOnlyHint: true`), or it is one of Home Assistant's that do. Any
    /// other one changes something.
    public static func reads(_ tool: MCPTool) -> Bool {
        tool.readOnlyHint ?? homeAssistantReads.contains(tool.name)
    }

    /// Home Assistant's tools that do what Maé's own actions do (timers, lists, the date and time, the calendar): off when
    /// the tool is added, so that her own are the ones used.
    static let builtInLike: Set<String> = [
        "GetDateTime", "HassGetCurrentDate", "HassGetCurrentTime", "todo_get_items", "HassListAddItem",
        "HassListCompleteItem", "HassShoppingListAddItem", "HassShoppingListCompleteItem", "HassShoppingListLastItems",
        "calendar_get_events", "HassStartTimer", "HassCancelTimer", "HassCancelAllTimers", "HassIncreaseTimer",
        "HassDecreaseTimer", "HassPauseTimer", "HassUnpauseTimer", "HassTimerStatus",
    ]

    /// Whether Maé has a built-in action for this tool (see `builtInLike`), by its name, Home Assistant's or another
    /// service's ("create_reminder", "set_timer", "get_current_time").
    public static func duplicatesBuiltIn(_ name: String) -> Bool {
        if builtInLike.contains(name) { return true }
        let words = Set(name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["timer", "timers", "reminder", "reminders", "alarm"])
            || words.contains("time") && (words.contains("current") || words.contains("get"))
            || words.contains("datetime")
    }

    // MARK: - Results

    /// A result as the model reads it: JSON when it is (Home Assistant answers with JSON), text otherwise.
    static func readable(_ text: String) -> JSONValue {
        if text.count < resultLimit, text.hasPrefix("{") || text.hasPrefix("["),
           let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        {
            return value
        }
        return .string(text)
    }

    /// At most `resultLimit` characters, cut at a line when it can be.
    static func capped(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > resultLimit else { return text }
        var cut = String(text.prefix(resultLimit))
        if let line = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: line) > resultLimit / 2 {
            cut = String(cut[..<line])
        }
        return cut + "\n[… coupé : la suite n'est pas montrée]"
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
    }
}
