import FakeHomeAssistant
import Foundation
import Testing

@testable import VoiceCore

private let nb = "\u{00A0}"

/// A pretend Home Assistant, started, and a client of it.
private func home(_ options: FakeHomeAssistant.Options = .init(), token: String? = nil,
                  timeout: Duration = .seconds(5)) async throws -> (FakeHomeAssistant, MCPClient)
{
    let server = FakeHomeAssistant(options: options)
    try await server.start()
    return (server, MCPClient(address: server.address, token: token, timeout: timeout))
}

/// The pretend Home Assistant as a connected tool just added (the switches a new tool starts with).
private func connected(_ server: FakeHomeAssistant, _ client: MCPClient, whenActing: ConnectedToolSettings.WhenActing = .askFirst)
    async throws -> (ConnectedTools, ConnectedToolSettings)
{
    var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .none,
                                         whenActing: whenActing)
    settings.actions = settings.merging(try await client.listTools())
    let tools = ConnectedTools()
    await tools.configure([ConnectedTools.Connection(settings: settings, client: client)])
    return (tools, settings)
}

private actor Collected {
    var reports: [ConnectedToolReport] = []
    func add(_ report: ConnectedToolReport) { reports.append(report) }
    var log: [ConnectedToolLogEntry.Result] {
        reports.compactMap { if case .log(_, let entry) = $0 { entry.result } else { nil } }
    }
}

/// What the user said, as the pipeline sends it.
private final class Users: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ text: String) { lock.withLock { list.append(text) } }
    var texts: [String] { lock.withLock { list } }
}

/// The cards' reports (`ConnectedToolAction`), in the order they are sent.
private final class Cards: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ConnectedToolAction] = []
    func add(_ report: ConnectedToolReport) {
        if case .action(let action) = report { lock.withLock { list.append(action) } }
    }
    var actions: [ConnectedToolAction] { lock.withLock { list } }
    var statuses: [ConnectedToolAction.Status] { actions.map(\.status) }
}

private func waitUntil(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

private let context = ToolContext(now: Date(), language: .french)

@Suite("Connected tools: the MCP client", .serialized)
struct MCPClientTests {
    @Test func connectsAndListsEveryPage() async throws {
        var options = FakeHomeAssistant.Options()
        options.pageSize = 3
        let (server, client) = try await home(options)
        defer { server.stop() }
        let tools = try await client.listTools()
        // As the user's Home Assistant listed them on 2026-10-27, with the thermostat's and the covers' two.
        #expect(tools.map(\.name) == [
            "assist_satellite__HassBroadcast", "climate__HassClimateSetTemperature", "homeassistant__GetLiveContext",
            "intent__HassTurnOn", "intent__HassTurnOff", "intent__HassSetPosition", "intent__HassCancelAllTimers",
            "light__HassLightSet", "llm__GetDateTime", "media_player__HassMediaUnpause", "media_player__HassMediaPause",
            "media_player__HassMediaNext", "media_player__HassMediaPrevious", "media_player__HassSetVolume",
            "media_player__HassSetVolumeRelative", "media_player__HassMediaPlayerMute", "media_player__HassMediaPlayerUnmute",
            "media_player__search_media", "media_player__play_media", "todo__get_items", "todo__HassListAddItem",
            "todo__HassListCompleteItem", "todo__HassListRemoveItem", "vacuum__HassVacuumStart",
            "vacuum__HassVacuumReturnToBase", "vacuum__HassVacuumCleanArea",
        ])
        let turnOn = try #require(tools.first { $0.name == "intent__HassTurnOn" })
        #expect(turnOn.title == "Turn on")
        #expect(turnOn.description.hasPrefix("Turns on/opens/presses a device or entity.") == true)
        #expect(turnOn.readOnlyHint == false)
        #expect(tools.filter { $0.readOnlyHint == true }.map(\.name)
            == ["homeassistant__GetLiveContext", "llm__GetDateTime", "media_player__search_media", "todo__get_items"])
    }

    /// Older versions of Home Assistant: no integration before the names, no titles, no annotations.
    @Test func listsTheOlderNamesWhenAskedTo() async throws {
        var options = FakeHomeAssistant.Options()
        options.olderNames = true
        let (server, client) = try await home(options)
        defer { server.stop() }
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["HassTurnOn", "HassTurnOff", "HassSetPosition", "HassListAddItem",
                                      "HassListCompleteItem", "HassLightSet", "HassClimateSetTemperature",
                                      "todo_get_items", "GetDateTime", "GetLiveContext"])
        #expect(tools.allSatisfy { $0.readOnlyHint == nil && $0.title == nil })
        #expect(!(try await client.call("HassTurnOn", arguments: ["area": "Salon"])).isError)
        // A name it does not list is no tool of its own, whichever version lists the other.
        #expect(try await client.call("intent__HassTurnOn", arguments: ["area": "Salon"]).isError)
        var newer = server.options
        newer.olderNames = false
        server.options = newer
        #expect(try await client.call("HassTurnOn", arguments: ["area": "Salon"]).text
            == "Error calling tool: Tool \"HassTurnOn\" not found")
        #expect(server.calls.map(\.name) == ["HassTurnOn", "intent__HassTurnOn", "HassTurnOn"])
    }

    @Test func keepsTheSessionItIsGivenAndStartsANewOneWhenItIsForgotten() async throws {
        var options = FakeHomeAssistant.Options()
        options.sessions = true
        let (server, client) = try await home(options)
        defer { server.stop() }
        #expect(try await client.listTools().count == FakeHomeAssistant.newerTools.count)
        server.forgetSession()
        let result = try await client.call("intent__HassTurnOn", arguments: ["area": "Salon"])
        #expect(!result.isError)
        #expect(server.calls.map(\.name) == ["intent__HassTurnOn"])
    }

    @Test func callsATool() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let result = try await client.call("intent__HassTurnOn", arguments: ["area": "Salon", "domain": ["light"]])
        #expect(!result.isError)
        #expect(result.text.contains("\"response_type\":\"action_done\""))
        #expect(result.text.contains("Plafonnier du salon"))
        #expect(server.calls == [.init(name: "intent__HassTurnOn", arguments: ["area": "Salon", "domain": ["light"]])])
        #expect(server.isOn("Plafonnier du salon") == true)
    }

    @Test func readsAnAnswerSentAsAStreamOfEvents() async throws {
        var options = FakeHomeAssistant.Options()
        options.stream = true
        options.saysToolsChanged = true
        let (server, client) = try await home(options)
        defer { server.stop() }
        #expect(try await client.listTools().count == FakeHomeAssistant.newerTools.count)
        let result = try await client.call("intent__HassTurnOff", arguments: ["name": "Lampe du bureau"])
        #expect(!result.isError)
        #expect(server.isOn("Lampe du bureau") == false)
        // The stream also said the list of tools changed.
        #expect(await client.toolsChanged)
    }

    @Test func aFailureTheToolReportsIsAResult() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let result = try await client.call("intent__HassTurnOn", arguments: ["area": "Garage"])
        #expect(result.isError)
        #expect(result.text == "Error calling tool: No area named Garage")
    }

    /// Newer versions read only what is asked (a room, a kind, a name), and act on the other devices they list tools for.
    @Test func readsTheHouseAsAskedAndActsOnItsOtherDevices() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let kitchen = try await client.call("homeassistant__GetLiveContext", arguments: ["area": "cuisine"]).text
        #expect(kitchen.contains("Lumière de la cuisine") && kitchen.contains("Robot aspirateur") && !kitchen.contains("Salon"))
        let lights = try await client.call("homeassistant__GetLiveContext", arguments: ["domain": "light", "area": "Salon"]).text
        #expect(lights.contains("Plafonnier du salon") && !lights.contains("Thermostat") && !lights.contains("Enceinte"))
        // A name is a device's: nothing found is an error, as Home Assistant says it.
        let room = try await client.call("homeassistant__GetLiveContext", arguments: ["name": "salon"])
        #expect(room.isError && room.text == "Error calling tool: No exposed entities matched name 'salon'")
        let pause = try await client.call("media_player__HassMediaPause", arguments: ["area": "Salon"])
        #expect(!pause.isError && pause.text.contains("Enceinte du salon"))
        #expect(!(try await client.call("vacuum__HassVacuumStart", arguments: [:])).isError)
    }

    @Test func sendsTheTokenAndTellsARefusedOne() async throws {
        var options = FakeHomeAssistant.Options()
        options.token = "the-right-token"
        let (server, client) = try await home(options, token: "the-right-token")
        defer { server.stop() }
        #expect(try await client.listTools().count == FakeHomeAssistant.newerTools.count)
        let wrong = MCPClient(address: server.address, token: "a-wrong-token", timeout: .seconds(5))
        await #expect(throws: MCPError.unauthorized) { try await wrong.listTools() }
        let none = MCPClient(address: server.address, token: nil, timeout: .seconds(5))
        await #expect(throws: MCPError.unauthorized) { try await none.listTools() }
    }

    @Test func aServerThatDoesNotAnswerTimesOut() async throws {
        var options = FakeHomeAssistant.Options()
        options.silent = true
        let (server, client) = try await home(options, timeout: .milliseconds(500))
        defer { server.stop() }
        let start = ContinuousClock.now
        await #expect(throws: MCPError.noAnswer) { try await client.listTools() }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func nothingAtTheAddressOrSomethingElse() async throws {
        let (server, _) = try await home()
        let port = server.port
        server.stop()
        let nobody = MCPClient(address: URL(string: "http://127.0.0.1:\(port)/api/mcp")!, token: nil, timeout: .seconds(2))
        await #expect(throws: MCPError.unreachable) { try await nobody.listTools() }
        let (other, _) = try await home()
        defer { other.stop() }
        let page = MCPClient(address: URL(string: "http://127.0.0.1:\(other.port)/other")!, token: nil, timeout: .seconds(2))
        await #expect(throws: MCPError.notMCP("404")) { try await page.listTools() }
    }

    @Test func addressesAsTyped() {
        #expect(MCPClient.address("homeassistant.local:8123/api/mcp")?.absoluteString
            == "http://homeassistant.local:8123/api/mcp")
        #expect(MCPClient.address("192.168.1.20:8123/api/mcp")?.absoluteString == "http://192.168.1.20:8123/api/mcp")
        #expect(MCPClient.address("mcp.example.org/mcp")?.absoluteString == "https://mcp.example.org/mcp")
        #expect(MCPClient.address("http://homeassistant.local:8123/api/mcp") != nil)
        #expect(MCPClient.address("ftp://example.org") == nil)
        #expect(MCPClient.address("not an address") == nil)
        #expect(MCPClient.isHomeNetwork("homeassistant.local"))
        #expect(MCPClient.isHomeNetwork("10.0.0.5"))
        #expect(!MCPClient.isHomeNetwork("8.8.8.8"))
        #expect(!MCPClient.isHomeNetwork("example.org"))
    }
}

@Suite("Connected tools: what the model sees and what the app does", .serialized)
struct ConnectedToolsTests {
    @Test func mapsHomeAssistantSchemas() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let tools = try await client.listTools()
        func parameters(_ name: String) -> [ToolParameter] {
            ConnectedTools.parameters(tools.first { $0.name == name }!.inputSchema)
        }
        let turnOn = parameters("intent__HassTurnOn")
        #expect(turnOn.map(\.name) == ["area", "device_class", "domain", "floor", "name"])
        #expect(turnOn[0].kind == .string)
        if case .strings(let classes) = turnOn[1].kind { #expect(classes.contains("shutter")) } else { Issue.record() }
        #expect(turnOn[2].kind == .strings([]))
        #expect(turnOn.allSatisfy { !$0.required })
        let climate = parameters("climate__HassClimateSetTemperature")
        #expect(climate.first { $0.name == "temperature" }.map { ($0.kind, $0.required) } ?? (.string, false) == (.number, true))
        let light = parameters("light__HassLightSet")
        #expect(light.first { $0.name == "brightness" }?.kind == .integer)
        #expect(light.first { $0.name == "brightness" }?.description
            == "The brightness percentage of the light between 0 and 100, where 0 is off and 100 is fully lit (0 to 100)")
        #expect(light.first { $0.name == "domain" }?.kind == .strings(["light"]))
        let todo = parameters("todo__get_items")
        #expect(todo.first { $0.name == "status" }?.kind == .oneOf(["needs_action", "completed", "all"]))
        // Newer versions filter what they read; a domain may be one or a list (passed on as written).
        let read = parameters("homeassistant__GetLiveContext")
        #expect(read.map(\.name) == ["area", "domain", "name"])
        if case .schema = read[1].kind {} else { Issue.record("domain: \(read[1].kind)") }
        #expect(read.allSatisfy { !$0.description.isEmpty && !$0.required })
        // What the model sees of Home Assistant's intents: their targets described, without `device_class`.
        let offered = ConnectedTools.parameters(tools.first { $0.name == "intent__HassTurnOn" }!)
        #expect(offered.map(\.name) == ["area", "domain", "floor", "name"])
        #expect(offered.allSatisfy { !$0.description.isEmpty })
        // Deeper: passed on as written.
        let deep: JSONValue = ["type": "object", "properties": ["filter": ["type": "object", "properties": ["a": ["type": "string"]]],
                                                                "ids": ["type": "array", "items": ["type": "integer"]]]]
        let kinds = ConnectedTools.parameters(deep).map(\.kind)
        #expect(kinds.allSatisfy { if case .schema = $0 { true } else { false } })
    }

    @Test func offersTheEnabledActionsWithTheirRisk() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, settings) = try await connected(server, client)
        // Off when added: what Maé has herself (timers, the date and time, lists), and, until the user turns them on, the
        // media players', the vacuums' and the broadcast.
        let offWhenAdded = settings.actions.filter { !$0.enabled }.map(\.name)
        #expect(offWhenAdded.filter { ConnectedTools.duplicatesBuiltIn($0) }
            == ["intent__HassCancelAllTimers", "llm__GetDateTime", "todo__get_items", "todo__HassListAddItem",
                "todo__HassListCompleteItem", "todo__HassListRemoveItem"])
        #expect(offWhenAdded.filter { !ConnectedTools.duplicatesBuiltIn($0) }
            == ["assist_satellite__HassBroadcast", "media_player__HassMediaUnpause", "media_player__HassMediaPause",
                "media_player__HassMediaNext", "media_player__HassMediaPrevious", "media_player__HassSetVolume",
                "media_player__HassSetVolumeRelative", "media_player__HassMediaPlayerMute",
                "media_player__HassMediaPlayerUnmute", "media_player__search_media", "media_player__play_media",
                "vacuum__HassVacuumStart", "vacuum__HassVacuumReturnToBase", "vacuum__HassVacuumCleanArea"])
        let specs = await tools.tools()
        #expect(specs.map(\.name) == ["climate__HassClimateSetTemperature", "homeassistant__GetLiveContext",
                                      "intent__HassTurnOn", "intent__HassTurnOff", "intent__HassSetPosition",
                                      "light__HassLightSet"])
        // Ask first: what acts waits for a "oui"; reading never does.
        #expect(await tools.risk(of: ToolCall(name: "intent__HassTurnOn")) == .sensitive)
        #expect(await tools.risk(of: ToolCall(name: "homeassistant__GetLiveContext")) == .read)
        // The server's own words, its title first.
        #expect(specs.first { $0.name == "intent__HassTurnOn" }?.description.hasPrefix("Turn on. Turns on/opens/presses") == true)
        #expect(await tools.promptAddendum()?.contains("« Home Assistant »") == true)
        // The media players' turned on by the user: offered, and they read or act as Home Assistant says.
        var media = settings
        for i in media.actions.indices where media.actions[i].name.hasPrefix("media_player__") {
            media.actions[i].enabled = true
        }
        #expect(await tools.configure([ConnectedTools.Connection(settings: media, client: client)]))
        #expect(await tools.tools().count == 16)
        #expect(await tools.risk(of: ToolCall(name: "media_player__search_media")) == .read)
        #expect(await tools.risk(of: ToolCall(name: "media_player__play_media")) == .sensitive)

        var direct = settings
        direct.whenActing = .doDirectly
        #expect(await tools.configure([ConnectedTools.Connection(settings: direct, client: client)]))
        #expect(await tools.risk(of: ToolCall(name: "intent__HassTurnOn")) == .undoable)
        #expect(await tools.risk(of: ToolCall(name: "homeassistant__GetLiveContext")) == .read)
        // Nothing changed: the model sees the same.
        #expect(!(await tools.configure([ConnectedTools.Connection(settings: direct, client: client)])))
        var off = direct
        off.enabled = false
        await tools.configure([ConnectedTools.Connection(settings: off, client: client)])
        #expect(await tools.tools().isEmpty)
        #expect(await tools.promptAddendum() == nil)
    }

    @Test func annotationsDecide() {
        let reads = MCPTool(name: "search_notes", description: "", readOnlyHint: true)
        let writes = MCPTool(name: "GetLiveContext", description: "", readOnlyHint: false)
        let silent = MCPTool(name: "create_note", description: "")
        #expect(ConnectedTools.reads(reads))
        #expect(!ConnectedTools.reads(writes))
        #expect(!ConnectedTools.reads(silent))
        #expect(ConnectedTools.reads(MCPTool(name: "GetLiveContext", description: "")))
        #expect(ConnectedTools.duplicatesBuiltIn("set_timer"))
        #expect(ConnectedTools.duplicatesBuiltIn("createReminder"))
        #expect(ConnectedTools.duplicatesBuiltIn("get_current_time"))
        #expect(!ConnectedTools.duplicatesBuiltIn("HassTurnOn"))
        #expect(!ConnectedTools.duplicatesBuiltIn("search_notes"))
    }

    /// Newer versions of Home Assistant put the integration before each tool's name, as the user's listed them on
    /// 2026-10-27: the rules read them as the older names.
    @Test func readsHomeAssistantsNamesWithTheirIntegration() {
        #expect(ConnectedTools.homeAssistantName("intent__HassTurnOn") == "HassTurnOn")
        #expect(ConnectedTools.homeAssistantName("light__HassLightSet") == "HassLightSet")
        #expect(ConnectedTools.homeAssistantName("homeassistant__GetLiveContext") == "GetLiveContext")
        #expect(ConnectedTools.homeAssistantName("todo__get_items") == "todo_get_items")
        #expect(ConnectedTools.homeAssistantName("HassTurnOn") == "HassTurnOn")
        #expect(ConnectedTools.homeAssistantName("search_notes") == "search_notes")
        #expect(ConnectedTools.homeAssistantName("__odd") == "__odd")
        // Off when added: what Maé does herself (lists, timers, the date)…
        for name in ["todo__HassListAddItem", "todo__HassListCompleteItem", "todo__HassListRemoveItem", "todo__get_items",
                     "intent__HassCancelAllTimers", "llm__GetDateTime"]
        {
            #expect(ConnectedTools.duplicatesBuiltIn(name), "\(name)")
        }
        // … but not the rest.
        for name in ["intent__HassTurnOn", "light__HassLightSet", "media_player__HassMediaPause", "vacuum__HassVacuumStart"] {
            #expect(!ConnectedTools.duplicatesBuiltIn(name), "\(name)")
        }
        // Off when added too, until the user turns them on: the media players', the vacuums' and the broadcast, by their
        // integration (one Home Assistant adds later as well) or by their older names.
        for name in ["media_player__HassMediaPause", "media_player__HassSetVolume", "media_player__search_media",
                     "media_player__play_media", "media_player__HassMediaShuffle", "vacuum__HassVacuumStart",
                     "vacuum__HassVacuumCleanArea", "assist_satellite__HassBroadcast", "HassMediaPause", "HassSetVolume",
                     "HassMediaSearchAndPlay", "HassVacuumStart", "HassBroadcast", "llm__GetDateTime"]
        {
            #expect(!ConnectedTools.onWhenAdded(name), "\(name)")
        }
        for name in ["intent__HassTurnOn", "intent__HassTurnOff", "intent__HassSetPosition", "light__HassLightSet",
                     "climate__HassClimateSetTemperature", "homeassistant__GetLiveContext", "HassTurnOn", "GetLiveContext",
                     "search_notes", "play_music"]
        {
            #expect(ConnectedTools.onWhenAdded(name), "\(name)")
        }
        #expect(ConnectedTools.reads(MCPTool(name: "homeassistant__GetLiveContext", description: "")))
        #expect(ConnectedToolPhrases.confirm(MCPTool(name: "intent__HassTurnOn", title: "Turn on", description: ""),
                                             ["area": "salon"], toolName: "Home Assistant")
            == "J’allume le salon avec Home Assistant. On y va\(nb)?")
        #expect(ConnectedToolPhrases.title(MCPTool(name: "homeassistant__GetLiveContext", description: ""), [:])
            == "Lire l’état de la maison")
        // The intents' targets are described, and their device_class left out.
        let schema: JSONValue = ["type": "object", "properties": ["area": ["type": "string"], "device_class": ["type": "string"]]]
        let parameters = ConnectedTools.parameters(MCPTool(name: "intent__HassTurnOn", description: "", inputSchema: schema))
        #expect(parameters.map(\.name) == ["area"])
        #expect(parameters.first?.description == ConnectedTools.homeAssistantTargets["area"])
    }

    @Test func showsTheExamplesWithHomeAssistantsNewerNames() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .none)
        settings.actions = settings.merging(["intent__HassTurnOn", "intent__HassTurnOff", "homeassistant__GetLiveContext",
                                            "todo__HassListAddItem"].map { MCPTool(name: $0, description: "") })
        #expect(settings.actions.map(\.enabled) == [true, true, true, false])
        let tools = ConnectedTools()
        await tools.configure([.init(settings: settings, client: client)])
        let examples = await tools.exampleExchanges(now: Date())
        #expect(examples.contains { $0.role == .assistant && $0.content == "J’allume le couloir avec Home Assistant. On y va\(nb)?" })
    }

    @Test func namesStayUnique() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let mine = MCPTool(name: "minuteur", description: "A timer of its own", inputSchema: ["type": "object"])
        var first = ConnectedToolSettings(name: "Maison", address: server.address.absoluteString, access: .none)
        first.actions = [.init(tool: MCPTool(name: "intent__HassTurnOn", description: "On"), enabled: true),
                         .init(tool: mine, enabled: true)]
        var second = ConnectedToolSettings(name: "Chalet", address: server.address.absoluteString, access: .none)
        second.actions = [.init(tool: MCPTool(name: "intent__HassTurnOn", description: "On"), enabled: true)]
        let tools = ConnectedTools()
        await tools.configure([.init(settings: first, client: client), .init(settings: second, client: client)])
        #expect(await tools.tools().map(\.name) == ["intent__HassTurnOn", "minuteur_2", "intent__HassTurnOn_2"])
        // The second one's call reaches the service under its own name.
        let outcome = try await tools.perform(ToolCall(name: "intent__HassTurnOn_2", arguments: ["area": "Salon"]),
                                              context: context)
        #expect(server.calls.map(\.name) == ["intent__HassTurnOn"])
        #expect(outcome.spoken == ConnectedToolPhrases.done)
    }

    @Test func saysWhatSheIsAboutToDo() {
        func confirm(_ name: String, _ arguments: [String: JSONValue]) -> String {
            ConnectedToolPhrases.confirm(MCPTool(name: name, description: ""), arguments, toolName: "Home Assistant")
        }
        #expect(confirm("HassTurnOn", ["area": "salon"]) == "J’allume le salon avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassTurnOff", ["domain": ["light"]]) == "J’éteins toutes les lumières avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassTurnOn", ["area": "Cuisine", "domain": ["light"]])
            == "J’allume les lumières de la cuisine avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassTurnOff", ["name": "Lampe du salon", "area": "Salon"])
            == "J’éteins la lampe du salon avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassLightSet", ["area": "salon", "brightness": 50])
            == "Je règle la lumière du salon à 50\(nb)% avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassClimateSetTemperature", ["temperature": .double(20)])
            == "Je règle le chauffage à 20\(nb)degrés avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassClimateSetTemperature", ["temperature": .double(20.5), "area": "Entrée"])
            == "Je règle le chauffage de l’entrée à 20,5\(nb)degrés avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassSetPosition", ["name": "volet du salon", "position": 0])
            == "Je ferme le volet du salon avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassTurnOn", ["name": "Volet de la chambre", "device_class": ["shutter"]])
            == "J’ouvre le volet de la chambre avec Home Assistant. On y va\(nb)?")
        #expect(confirm("HassTurnOn", ["name": "Nova"]) == "J’allume «\(nb)Nova\(nb)» avec Home Assistant. On y va\(nb)?")
        // Any other action: the tool, the action, its arguments.
        #expect(confirm("HassVacuumStart", ["name": "Robot"])
            == "Je demande à Home Assistant\(nb): «\(nb)HassVacuumStart\(nb)» (name\(nb): Robot). On y va\(nb)?")
        #expect(ConnectedToolPhrases.title(MCPTool(name: "HassTurnOn", description: ""), ["area": "salon"]) == "Allumer le salon")
        #expect(ConnectedToolPhrases.title(MCPTool(name: "GetLiveContext", description: ""), [:]) == "Lire l’état de la maison")
    }

    @Test func saysTheActionOnItsCard() {
        func card(_ name: String, _ arguments: [String: JSONValue]) -> ConnectedToolPhrases.CardWords {
            ConnectedToolPhrases.card(MCPTool(name: name, description: ""), arguments)
        }
        #expect(card("intent__HassTurnOn", ["area": "salon"]) == .init(verb: "Allumer", target: "Salon", result: "Salon allumé"))
        #expect(card("intent__HassTurnOff", ["area": "Cuisine"])
            == .init(verb: "Éteindre", target: "Cuisine", result: "Cuisine éteinte"))
        #expect(card("intent__HassTurnOff", ["domain": ["light"]])
            == .init(verb: "Éteindre", target: "Toutes les lumières", result: "Toutes les lumières éteintes"))
        #expect(card("intent__HassTurnOn", ["area": "Cuisine", "domain": ["light"]])
            == .init(verb: "Allumer", target: "Lumières de la cuisine", result: "Lumières de la cuisine allumées"))
        #expect(card("intent__HassTurnOff", ["name": "Lampe du salon", "area": "Salon"])
            == .init(verb: "Éteindre", target: "Lampe du salon", result: "Lampe du salon éteinte"))
        #expect(card("intent__HassTurnOn", ["domain": ["cover"]])
            == .init(verb: "Ouvrir", target: "Tous les volets", result: "Tous les volets ouverts"))
        #expect(card("intent__HassTurnOn", ["area": "Entrée"]) == .init(verb: "Allumer", target: "Entrée", result: "Entrée allumée"))
        #expect(card("intent__HassSetPosition", ["name": "volet du salon", "position": 0])
            == .init(verb: "Fermer", target: "Volet du salon", result: "Volet du salon fermé"))
        // A setting: what it is set to is the result.
        #expect(card("light__HassLightSet", ["area": "salon", "brightness": 50])
            == .init(verb: "Régler", target: "Lumière du salon à 50\(nb)%", result: "Lumière du salon à 50\(nb)%"))
        #expect(card("climate__HassClimateSetTemperature", ["temperature": .double(20)])
            == .init(verb: "Régler", target: "Chauffage à 20\(nb)degrés", result: "Chauffage à 20\(nb)degrés"))
        #expect(card("media_player__HassMediaPause", [:])
            == .init(verb: "Mettre en pause", target: "Musique", result: "Musique en pause"))
        #expect(card("media_player__HassMediaNext", ["area": "salon"])
            == .init(verb: "Passer à la suite", target: "Lecteur du salon", result: nil))
        // A name whose gender cannot be told: no result (the card shows the log's line).
        #expect(card("intent__HassTurnOn", ["name": "Nova"]) == .init(verb: "Allumer", target: "Nova", result: nil))
        // An older Home Assistant's names, without the integration before them: the same words.
        #expect(card("HassTurnOn", ["area": "salon"]) == .init(verb: "Allumer", target: "Salon", result: "Salon allumé"))
        #expect(card("HassMediaPause", [:]) == .init(verb: "Mettre en pause", target: "Musique", result: "Musique en pause"))
        // Any other action: its title and its arguments' values.
        #expect(ConnectedToolPhrases.card(MCPTool(name: "create_note", title: "Créer une note", description: ""),
                                          ["title": "Courses", "tags": ["maison", "liste"]])
            == .init(verb: "Créer une note", target: "maison, liste, Courses", result: nil))
        #expect(ConnectedToolPhrases.card(MCPTool(name: "sync", description: ""), [:])
            == .init(verb: "sync", target: nil, result: nil))
    }

    /// The card of an action that changes something: it waits for the « oui », then says what came of it, with the same
    /// id; it goes when the action is dropped. Reading has none; done directly, only what came of it.
    @Test func sendsTheActionsCardAtEachMoment() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, settings) = try await connected(server, client)
        let cards = Cards()
        await tools.observe { cards.add($0) }
        let runner = ToolRunner(providers: [tools], actions: false)
        _ = await runner.tools()
        func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> ToolCall {
            ToolCall(name: name, arguments: arguments)
        }
        _ = await runner.handle(call("intent__HassTurnOn", ["area": "salon"]), context: context)
        _ = await runner.resolve(.confirm, context: context)
        _ = await runner.handle(call("intent__HassTurnOff", ["area": "cuisine"]), context: context)
        _ = await runner.resolve(.decline, context: context)
        // Another request replaces the one that waits (a question, which has no card).
        _ = await runner.handle(call("intent__HassTurnOn", ["area": "bureau"]), context: context)
        _ = await runner.handle(call("homeassistant__GetLiveContext"), context: context)
        _ = await runner.handle(call("intent__HassTurnOn", ["area": "Garage"]), context: context)
        _ = await runner.resolve(.confirm, context: context)
        // A new conversation.
        _ = await runner.handle(call("intent__HassTurnOn", ["area": "chambre"]), context: context)
        await runner.resetConversation()
        #expect(cards.statuses == [.waiting, .done, .waiting, .refusedByUser, .waiting, .dropped, .waiting,
                                   .failed(.said("Error calling tool: No area named Garage")), .waiting, .dropped])
        let actions = cards.actions
        for pair in stride(from: 0, to: actions.count, by: 2) { #expect(actions[pair].id == actions[pair + 1].id) }
        #expect(Set(actions.map(\.id)).count == 5)
        #expect(actions.allSatisfy { $0.toolID == settings.id && $0.toolName == "Home Assistant" })
        #expect(actions[1].words == .init(verb: "Allumer", target: "Salon", result: "Salon allumé"))
        #expect(actions[1].title == "Allumer le salon")
        #expect(actions[3].words.result == "Cuisine éteinte")

        // Done directly: only what came of it.
        var direct = settings
        direct.whenActing = .doDirectly
        await tools.configure([ConnectedTools.Connection(settings: direct, client: client)])
        let doing = ToolRunner(providers: [tools], actions: false)
        _ = await doing.tools()
        _ = await doing.handle(call("intent__HassTurnOff", ["area": "salon"]), context: context)
        _ = await doing.handle(call("homeassistant__GetLiveContext"), context: context)
        #expect(cards.statuses.suffix(1) == [.done])
        #expect(cards.actions.last?.words.result == "Salon éteint")

        // What the app gets is plain data.
        let event = try JSONEncoder().encode(AssistantEvent.connectedToolAction(actions[1]))
        guard case .connectedToolAction(let decoded) = try JSONDecoder().decode(AssistantEvent.self, from: event) else {
            Issue.record("not decoded as a card")
            return
        }
        #expect(decoded == actions[1])
    }

    /// The card's « Oui » and « Non » (`submit(answer:)`) are answers as spoken ones are: the action waits, then is
    /// carried out or refused, without the model.
    @Test(arguments: [true, false])
    func theCardsButtonsAnswerAsTheVoiceDoes(yes: Bool) async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client)
        let cards = Cards()
        await tools.observe { cards.add($0) }
        let model = ScriptedModel(scripts: [[.toolCall(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "salon"]))]])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker,
                                     tools: ToolRunner(providers: [tools], actions: false))
        let users = Users()
        Task { for await event in pipeline.events { if case .userTranscript(let text, _) = event { users.add(text) } } }
        try await pipeline.start()
        await pipeline.submit(text: "Allume le salon")
        await waitUntil {
            let played = await speaker.played
            return cards.statuses == [.waiting] && played > 0
        }
        await pipeline.submit(answer: yes)
        await waitUntil { cards.statuses.count == 2 }
        #expect(cards.statuses == [.waiting, yes ? .done : .refusedByUser])
        #expect(server.calls.map(\.name) == (yes ? ["intent__HassTurnOn"] : []))
        #expect(users.texts == ["Allume le salon", yes ? "Oui" : "Non"])
        #expect(await model.requests.count == 1)  // the answer never reached the model
        await pipeline.stop()
    }

    @Test func asksFirstThenDoesOrNotAndKeepsALog() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client)
        let collected = Collected()
        await tools.observe { report in Task { await collected.add(report) } }
        let runner = ToolRunner(providers: [tools], actions: false)
        _ = await runner.tools()
        let now = Date()
        let context = ToolContext(now: now, language: .french)

        // « Allume le salon », then « non »: nothing reaches Home Assistant.
        var reply = await runner.handle(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "salon"]), context: context)
        #expect(reply.spoken == "J’allume le salon avec Home Assistant. On y va\(nb)?")
        #expect(await runner.interception(for: "non", now: now) == .decline)
        _ = await runner.resolve(.decline, context: context)
        #expect(server.calls.isEmpty)

        // Again, then « oui »: done, and the model says it from Home Assistant's answer.
        _ = await runner.handle(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "salon"]), context: context)
        reply = try #require(await runner.resolve(.confirm, context: context))
        #expect(server.calls.map(\.name) == ["intent__HassTurnOn"])
        #expect(reply.modelSpeaks)
        #expect(reply.spoken == ConnectedToolPhrases.done)
        // "annule": MCP cannot undo.
        #expect(await runner.interception(for: "annule", now: now) == .undo)
        reply = try #require(await runner.resolve(.undo, context: context))
        #expect(reply.spoken == "Je ne peux pas défaire ce que j’ai demandé à Home Assistant.")

        // Reading never asks.
        reply = await runner.handle(ToolCall(name: "homeassistant__GetLiveContext"), context: context)
        #expect(reply.modelSpeaks)
        #expect(server.calls.map(\.name) == ["intent__HassTurnOn", "homeassistant__GetLiveContext"])
        if case .object(let result) = reply.forModel, case .object(let read)? = result["résultat"] {
            #expect(read["result"]?.text?.contains("Plafonnier du salon") == true)
        } else {
            Issue.record("unexpected result: \(reply.forModel)")
        }

        // An answer that says it failed: told as a failure.
        _ = await runner.handle(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "Garage"]), context: context)
        reply = try #require(await runner.resolve(.confirm, context: context))
        #expect(reply.spoken == "Home Assistant n’a pas pu le faire.")
        if case .object(let result) = reply.forModel {
            #expect(result["échec"]?.text == "Error calling tool: No area named Garage")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await collected.log == [.refusedByUser, .done, .done, .failed(.said("Error calling tool: No area named Garage"))])
    }

    @Test func severalActionsOfOneRequestAskOnceAndSayItOnce() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client)
        let runner = ToolRunner(providers: [tools], actions: false)
        _ = await runner.tools()
        // « Allume le salon et la cuisine », as the model may write it: two calls in one request, one question.
        _ = await runner.handle(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "salon"]), context: context)
        _ = await runner.handle(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "cuisine"]), context: context,
                                sameRequest: true)
        #expect(await runner.pendingQuestion(.french)
            == "J’allume le salon avec Home Assistant et j’allume la cuisine avec Home Assistant\(nb): on y va\(nb)?")
        let reply = try #require(await runner.resolve(.confirm, context: context))
        #expect(server.calls.map(\.name) == ["intent__HassTurnOn", "intent__HassTurnOn"])
        #expect(reply.spoken == ConnectedToolPhrases.done)
    }

    @Test func showsHowToCallAHomeAssistantWithoutTheActions() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client)
        let written: @Sendable (ToolCall) async -> String? = { call in
            let shown = call.arguments.keys.sorted().map { key in
                let value: String = if case .array(let items)? = call.arguments[key] {
                    "[" + items.compactMap(\.text).joined(separator: ",") + "]"
                } else {
                    call.arguments[key]?.text ?? ""
                }
                return "\(key)=\(value)"
            }
            return "<\(call.name) \(shown.joined(separator: " "))>"
        }
        let without = try #require(await tools.promptAddendum(actions: false, writeCall: written))
        #expect(without.hasSuffix(" Exemples : à « Allume le couloir », ta réponse entière est <intent__HassTurnOn area=couloir> ; "
            + "à « Ferme tous les volets », <intent__HassTurnOff domain=[cover]>"))
        let alone = await tools.promptAddendum()
        #expect(await tools.promptAddendum(actions: true, writeCall: written) == alone)
        // The examples of the smallest tier: the turning on asked first and the user's « Oui », then a question.
        let examples = await tools.exampleExchanges(now: Date())
        #expect(examples.filter { $0.role == .user }.map { $0.content.components(separatedBy: "\n").first ?? "" }
            == ["Allume le couloir", "Oui", "Est-ce que la lumière du garage est allumée ?"])
        #expect(examples.contains { $0.role == .assistant && $0.content == "J’allume le couloir avec Home Assistant. On y va\(nb)?" })
        // Another service: no example, there is no telling what its actions do.
        var other = ConnectedToolSettings(name: "Notes", address: server.address.absoluteString, access: .none)
        other.actions = [.init(tool: MCPTool(name: "create_note", description: "Creates a note."), enabled: true)]
        let notes = ConnectedTools()
        await notes.configure([.init(settings: other, client: client)])
        #expect(await notes.exampleExchanges(now: Date()).isEmpty)
        #expect(await notes.promptAddendum(actions: false, writeCall: written) == (await notes.promptAddendum()))
    }

    @Test func sendsOnlyTheArgumentsTheToolTakes() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client, whenActing: .doDirectly)
        // Home Assistant refuses an argument its tool does not list ("extra keys not allowed").
        _ = try await tools.perform(ToolCall(name: "homeassistant__GetLiveContext", arguments: ["entity": "cuisine"]),
                                    context: context)
        _ = try await tools.perform(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "salon", "pièce": "salon"]),
                                    context: context)
        #expect(server.calls.map(\.arguments) == [[:], ["area": "salon"]])
        let open: JSONValue = ["type": "object", "properties": ["a": ["type": "string"]], "additionalProperties": true]
        #expect(ConnectedTools.declared(["a": "1", "b": "2"], open) == ["a": "1", "b": "2"])
        #expect(ConnectedTools.declared(["b": "2"], ["type": "object"]) == ["b": "2"])
    }

    /// Home Assistant's newer reading tool, with filters that find nothing (a kind as a name): the whole house is read.
    @Test func readsTheWholeHouseWhenItsFiltersFindNothing() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client)
        let outcome = try await tools.perform(ToolCall(name: "homeassistant__GetLiveContext",
                                                       arguments: ["area": "salon", "name": "lumière"]), context: context)
        #expect(server.calls.map(\.arguments) == [["area": "salon", "name": "lumière"], [:]])
        if case .object(let result) = outcome.forModel, case .object(let read)? = result["résultat"] {
            #expect(read["result"]?.text?.contains("Lumière de la cuisine") == true)
        } else {
            Issue.record("unexpected result: \(outcome.forModel)")
        }
        // Filters that find something are kept; another tool's failure is told as it is.
        _ = try await tools.perform(ToolCall(name: "homeassistant__GetLiveContext", arguments: ["area": "cuisine"]),
                                    context: context)
        _ = try await tools.perform(ToolCall(name: "intent__HassTurnOn", arguments: ["area": "Garage"]), context: context)
        #expect(server.calls.count == 4)
    }

    @Test func doesItDirectlyWhenToldTo() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client, whenActing: .doDirectly)
        let runner = ToolRunner(providers: [tools], actions: false)
        _ = await runner.tools()
        let reply = await runner.handle(ToolCall(name: "intent__HassTurnOff", arguments: ["domain": ["light"]]), context: context)
        #expect(server.calls.map(\.name) == ["intent__HassTurnOff"])
        #expect(reply.modelSpeaks)
        #expect(server.isOn("Lampe du bureau") == false)
    }

    @Test func aServiceThatCannotBeReachedIsToldAndLogged() async throws {
        let (server, client) = try await home(token: "a-token-it-does-not-want")
        var options = server.options
        options.token = "another"
        server.options = options
        defer { server.stop() }
        var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .token)
        settings.actions = [.init(tool: MCPTool(name: "HassTurnOn", description: ""), enabled: true)]
        let tools = ConnectedTools()
        let collected = Collected()
        await tools.observe { report in Task { await collected.add(report) } }
        await tools.configure([.init(settings: settings, client: client)])
        await #expect(throws: ToolRefusal.self) {
            try await tools.perform(ToolCall(name: "HassTurnOn", arguments: ["area": "salon"]), context: context)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await collected.reports.contains(.state(settings.id, .needsReconnect)))
        #expect(await collected.log == [.failed(.unauthorized)])
    }

    @Test func capsALongResult() async throws {
        var options = FakeHomeAssistant.Options()
        options.extraDevices = 200
        let (server, client) = try await home(options)
        defer { server.stop() }
        let (tools, _) = try await connected(server, client)
        let outcome = try await tools.perform(ToolCall(name: "homeassistant__GetLiveContext"), context: context)
        guard case .object(let result) = outcome.forModel, let text = result["résultat"]?.text else {
            Issue.record("unexpected result: \(outcome.forModel)")
            return
        }
        #expect(text.count <= ConnectedTools.resultLimit + 60)
        #expect(text.hasSuffix("[… coupé : la suite n'est pas montrée]"))
    }

    @Test func settingsKeepTheToolsAndReadOlderOnes() throws {
        var settings = AssistantSettings()
        var tool = ConnectedToolSettings(name: "Home Assistant", address: "http://homeassistant.local:8123/api/mcp",
                                         access: .token)
        tool.actions = tool.merging([MCPTool(name: "HassTurnOn", description: "On",
                                             inputSchema: ["type": "object", "properties": ["area": ["type": "string"]]])])
        settings.connectedTools = [tool]
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.connectedTools == [tool])
        let older = try JSONDecoder().decode(AssistantSettings.self, from: Data(#"{"actionsEnabled": true}"#.utf8))
        #expect(older.connectedTools.isEmpty)
        // A new list keeps the switches of the actions already known.
        var known = tool
        known.actions[0].enabled = false
        let merged = known.merging([MCPTool(name: "HassTurnOn", description: "On"), MCPTool(name: "HassTurnOff", description: "Off")])
        #expect(merged.map(\.enabled) == [false, true])
        // A media player's action starts off; one the user turned on stays on when the list comes again.
        var media = known
        media.actions = media.merging([MCPTool(name: "media_player__HassMediaPause", description: "")])
        #expect(media.actions.map(\.enabled) == [false])
        media.actions[0].enabled = true
        #expect(media.merging([MCPTool(name: "media_player__HassMediaPause", description: ""),
                               MCPTool(name: "media_player__HassMediaNext", description: "")]).map(\.enabled) == [true, false])
    }
}
