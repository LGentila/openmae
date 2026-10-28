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
    /// The first Home Assistant that is on, for the examples a runner without the actions shows (`exampleExchanges`).
    private var homeExample: HomeExample?
    private var report: @Sendable (ConnectedToolReport) -> Void = { _ in }

    /// A Home Assistant that is on: the examples' turning on (with the service's tool, for its question), turning off and
    /// reading as the model calls them, the tool's name, and whether it asks first.
    private struct HomeExample {
        var turnOn: (call: ToolCall, tool: MCPTool)
        var turnOff: ToolCall?
        var read: ToolCall?
        var name: String
        var asksFirst: Bool
    }

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
        homeExample = nil
        for (index, connection) in self.connections.enumerated() {
            let names = offered.filter { $0.value.connection == index }
            func named(_ name: String) -> (key: String, value: (connection: Int, tool: MCPTool))? {
                names.first { Self.homeAssistantName($0.value.tool.name) == name }
            }
            guard let turnOn = named("HassTurnOn") else { continue }
            let turnOff = named("HassTurnOff")
            let read = named("GetLiveContext")?.key
            homeExample = HomeExample(
                turnOn: (ToolCall(name: turnOn.key, arguments: Self.examples[0].arguments), turnOn.value.tool),
                turnOff: turnOff.map { ToolCall(name: $0.key, arguments: Self.examples[1].arguments) },
                read: read.map { ToolCall(name: $0) }, name: connection.settings.name,
                asksFirst: connection.settings.whenActing == .askFirst)
            break
        }
        return before.0 != specs || before.1 != addendum
    }

    // `async` like the protocol's defaults: a synchronous version would lose to them in async callers.
    public func tools() async -> [ToolSpec] { specs }

    public func promptAddendum() async -> String? { addendum }

    /// Without the actions, whose part of the prompt is the one that shows how to call a tool, the same with example calls
    /// of a Home Assistant that is on, written the model's way (as the delegation's part has one of its own): a room, then
    /// all the devices of a kind (Gemma 4 E2B and E4B answered « J'éteins toutes les lumières. » without a call).
    public func promptAddendum(actions: Bool, writeCall: @Sendable (ToolCall) async -> String?) async -> String? {
        guard let addendum, !actions, let example = homeExample, let first = await writeCall(example.turnOn.call) else {
            return addendum
        }
        var text = addendum + " Exemples : à « \(Self.examples[0].request) », ta réponse entière est \(first)"
        if let turnOff = example.turnOff, let second = await writeCall(turnOff) {
            text += " ; à « \(Self.examples[1].request) », \(second)"
        }
        return text
    }

    /// On the smallest tier without the actions (`PipelineConfig.actionExamples`), conversations start with these
    /// exchanges, as if they had happened, when a Home Assistant is on: « Allume le couloir » (its question, then the
    /// user's « Oui », or done at once with "Do it directly"), then a question that only reads. None for another service:
    /// there is no telling what its actions do. Gemma 4 E2B called no connected tool without them (`voice-cli
    /// connected-tools --tier minimum`: « Je peux allumer le salon. », « J'éteins toutes les lumières. », nothing done).
    /// The second example of the prompt's part as an exchange too (« Ferme tous les volets », refused) made it worse: E2B
    /// then wrote `domain` for a room's lights or a room's shutter, as the example does for all the shutters.
    public func exampleExchanges(now: Date) async -> [ChatMessage] {
        exampleExchanges(now: now, timeZone: .current)
    }

    /// `exampleExchanges(now:)`, their date lines in `timeZone` (voice-cli actions-bench's reference time).
    public func exampleExchanges(now: Date, timeZone: TimeZone) -> [ChatMessage] {
        guard let example = homeExample else { return [] }
        let dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
        func said(_ text: String) -> ChatMessage { Conversation.userMessage(text, language: .french, dateLine: dateLine) }
        let call = example.turnOn.call
        var messages: [ChatMessage] = [said(Self.examples[0].request), .call(call)]
        if example.asksFirst {
            messages += [.result(of: call, ["statut": "en attente du oui de l'utilisateur"]),
                         ChatMessage(.assistant, ConnectedToolPhrases.confirm(example.turnOn.tool, call.arguments,
                                                                              toolName: example.name)),
                         said("Oui"), ChatMessage(.assistant, ConnectedToolPhrases.done)]
        } else {
            messages += [.result(of: call, ["résultat": Self.exampleDone]),
                         ChatMessage(.assistant, "C’est fait, le couloir est allumé.")]
        }
        if let read = example.read {
            messages += [said("Est-ce que la lumière du garage est allumée ?"), .call(read),
                         .result(of: read, ["résultat": Self.exampleHouse]),
                         ChatMessage(.assistant, "Non, la lumière du garage est éteinte.")]
        }
        return messages
    }

    /// The requests of the examples and their calls' arguments. Not requests of the benchmarks' corpora: a model that
    /// copied one instead of the user's words must not be counted right.
    static let examples: [(request: String, arguments: [String: JSONValue])] = [
        ("Allume le couloir", ["area": "couloir"]),
        ("Ferme tous les volets", ["domain": ["cover"]]),
    ]
    /// What Home Assistant answers, as the model reads it: the turning on done, and the house for the question.
    static let exampleDone: JSONValue = [
        "speech": [:], "response_type": "action_done",
        "data": ["targets": [], "success": [["name": "Couloir", "type": "area", "id": "couloir"]], "failed": []],
    ]
    static let exampleHouse: JSONValue = [
        "success": true,
        "result": .string("Live Context: An overview of the areas and the devices in this smart home:\n"
            + "- names: Plafonnier du couloir\n  domain: light\n  state: 'on'\n  areas: Couloir\n"
            + "- names: Lumière du garage\n  domain: light\n  state: 'off'\n  areas: Garage"),
    ]

    public func risk(of call: ToolCall) async -> ToolRisk {
        specs.first { $0.name == call.name }?.risk ?? .sensitive
    }

    /// A read the model writes after words of its own is left out, with the actions or without them: not carried out,
    /// kept out of the history, and nothing said of it (`ToolRunner.ignoresAfterWords`). The prompt's part has the model
    /// call these tools at once, without a word before (`promptAddendum`): a read after an answer is one the user did not
    /// ask for, unless the model gave a call a fair chance at its first token (`readMeantFrom`; unknown counts as none).
    /// An action that changes something is never left out: with "Ask first", it waits for the user's "oui".
    ///
    /// In voice-cli actions-bench with the pretend Home Assistant (its older tool names), Gemma 4 E4B read the house after
    /// an answer of its own to requests that asked nothing of it in 3 of 8 runs of Tests/Fixtures/actions-fr.json, with
    /// the actions or without them (« Merci beaucoup, c'est parfait » : « De rien, je suis là pour toi. », then
    /// GetLiveContext; « Qu'est-ce que tu sais faire ? »; « Tu peux me rappeler pourquoi le ciel est bleu ? »), each time
    /// with a call under 0.0001 % at its first token: the user then heard about their house, unasked, after the answer.
    /// Asked about it without the actions (Tests/Fixtures/home-assistant-fr.json), it read after a few words of its own
    /// for 3 of 28 questions (« Je vérifie ça pour toi tout de suite. »), none of 16 with them; it gives each of that
    /// corpus's four questions 55 to 99 % at its first token, so these reads are kept. A read that the model gave less is
    /// left out, and the user hears its words alone: with an earlier prompt, E4B gave 0.0005 % to « Est-ce que la lumière
    /// du salon est allumée ? » and answered « Laisse-moi vérifier l'état de la lumière du salon. » before reading. Gemma 4
    /// E2B and 26B wrote no call to it after words of their own; they give those questions over 20 % at their first
    /// token, but for « Le volet de la chambre est ouvert ? », 0.5 % on E2B without the actions, which it answers in words
    /// without reading.
    public func ignoresAfterWords(_ tool: String, actions: Bool, callChanceAtStart: Double?) async -> Bool {
        specs.first { $0.name == tool }?.risk == .read && (callChanceAtStart ?? 0) < Self.readMeantFrom
    }

    /// The chance of a call at the answer's first token from which a read written after words is kept
    /// (`ignoresAfterWords`), as a hand-over is (`AgentCatalog.handOverMeantFrom`).
    public static let readMeantFrom = 0.1

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
            let result = try await send(tool, call.arguments, to: connection)
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

    /// A call as the service gets it: only the arguments its tool takes (`declared`). Home Assistant's newer reading tool
    /// filters what it reads by area, domain and name, which it matches exactly, and the models write a kind or a measure
    /// as a name (`{area: salon, domain: light, name: lumière}`, `{name: temperature}`: `voice-cli actions-bench` with
    /// Tests/Fixtures/home-assistant-fr.json, on every tier): when its filters find nothing, the whole house is read, as
    /// older versions always do (cut at `resultLimit`).
    private func send(_ tool: MCPTool, _ arguments: [String: JSONValue], to connection: Connection) async throws
        -> MCPCallResult
    {
        let declared = Self.declared(arguments, tool.inputSchema)
        let result = try await connection.client.call(tool.name, arguments: declared)
        guard result.isError, !declared.isEmpty, Self.homeAssistantName(tool.name) == "GetLiveContext" else { return result }
        return try await connection.client.call(tool.name, arguments: [:])
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
        guard homeAssistantName(tool.name).hasPrefix("Hass") else { return parameters }
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

    // MARK: - Home Assistant's names

    /// A Home Assistant tool's name as older versions list it, which the rules here know: newer ones put the
    /// integration that offers it before it (`intent__HassTurnOn`, `homeassistant__GetLiveContext`, `llm__GetDateTime`,
    /// `todo__get_items`, as the user's Home Assistant listed them on 2026-10-27). A `Hass…` intent or a `Get…` tool keeps
    /// its own name; another one is named after its integration, as before (`todo_get_items`). Any other name is
    /// returned as it is.
    public static func homeAssistantName(_ name: String) -> String {
        guard let separator = name.range(of: "__", options: .backwards), separator.lowerBound > name.startIndex,
              separator.upperBound < name.endIndex
        else { return name }
        let integration = name[..<separator.lowerBound]
        let base = String(name[separator.upperBound...])
        return base.first?.isUppercase == true ? base : "\(integration)_\(base)"
    }

    // MARK: - What is safe

    /// The reading tools of Home Assistant, which older versions list without annotations.
    static let homeAssistantReads: Set<String> = ["GetLiveContext", "GetDateTime", "todo_get_items", "calendar_get_events",
                                                  "HassGetState", "HassGetWeather", "HassGetCurrentDate",
                                                  "HassGetCurrentTime"]

    /// A tool that only reads: the service says so (`readOnlyHint: true`), or it is one of Home Assistant's that do. Any
    /// other one changes something.
    public static func reads(_ tool: MCPTool) -> Bool {
        tool.readOnlyHint ?? homeAssistantReads.contains(homeAssistantName(tool.name))
    }

    /// Home Assistant's tools that do what Maé's own actions do (timers, lists, the date and time, the calendar): off when
    /// the tool is added, so that her own are the ones used.
    static let builtInLike: Set<String> = [
        "GetDateTime", "HassGetCurrentDate", "HassGetCurrentTime", "todo_get_items", "HassListAddItem",
        "HassListCompleteItem", "HassListRemoveItem", "HassShoppingListAddItem", "HassShoppingListCompleteItem", "HassShoppingListLastItems",
        "calendar_get_events", "HassStartTimer", "HassCancelTimer", "HassCancelAllTimers", "HassIncreaseTimer",
        "HassDecreaseTimer", "HassPauseTimer", "HassUnpauseTimer", "HassTimerStatus",
    ]

    /// Whether Maé has a built-in action for this tool (see `builtInLike`), by its name, Home Assistant's or another
    /// service's ("create_reminder", "set_timer", "get_current_time").
    public static func duplicatesBuiltIn(_ name: String) -> Bool {
        if builtInLike.contains(homeAssistantName(name)) { return true }
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

    /// The arguments the service's tool takes: those its schema lists, when it lists them and takes no others
    /// (`additionalProperties`). Home Assistant refuses any other one ("extra keys not allowed"), and a model may add one:
    /// Gemma 4 E4B wrote `GetLiveContext {entity: cuisine}` (`voice-cli connected-tools --tier standard`).
    static func declared(_ arguments: [String: JSONValue], _ schema: JSONValue) -> [String: JSONValue] {
        guard case .object(let object) = schema, case .object(let properties)? = object["properties"] else { return arguments }
        switch object["additionalProperties"] {
        case .bool(true)?, .object?: return arguments
        default: return arguments.filter { properties[$0.key] != nil }
        }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
    }
}
