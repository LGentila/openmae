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

private let context = ToolContext(now: Date(), language: .french)

@Suite("Connected tools: the MCP client", .serialized)
struct MCPClientTests {
    @Test func connectsAndListsEveryPage() async throws {
        var options = FakeHomeAssistant.Options()
        options.pageSize = 3
        let (server, client) = try await home(options)
        defer { server.stop() }
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["HassTurnOn", "HassTurnOff", "HassSetPosition", "HassListAddItem",
                                      "HassListCompleteItem", "HassLightSet", "HassClimateSetTemperature",
                                      "todo_get_items", "GetDateTime", "GetLiveContext"])
        #expect(tools.first?.description.hasPrefix("Turns on/opens/presses a device or entity.") == true)
        #expect(tools.allSatisfy { $0.readOnlyHint == nil })
    }

    @Test func keepsTheSessionItIsGivenAndStartsANewOneWhenItIsForgotten() async throws {
        var options = FakeHomeAssistant.Options()
        options.sessions = true
        let (server, client) = try await home(options)
        defer { server.stop() }
        #expect(try await client.listTools().count == 10)
        server.forgetSession()
        let result = try await client.call("HassTurnOn", arguments: ["area": "Salon"])
        #expect(!result.isError)
        #expect(server.calls.map(\.name) == ["HassTurnOn"])
    }

    @Test func callsATool() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let result = try await client.call("HassTurnOn", arguments: ["area": "Salon", "domain": ["light"]])
        #expect(!result.isError)
        #expect(result.text.contains("\"response_type\":\"action_done\""))
        #expect(result.text.contains("Plafonnier du salon"))
        #expect(server.calls == [.init(name: "HassTurnOn", arguments: ["area": "Salon", "domain": ["light"]])])
        #expect(server.isOn("Plafonnier du salon") == true)
    }

    @Test func readsAnAnswerSentAsAStreamOfEvents() async throws {
        var options = FakeHomeAssistant.Options()
        options.stream = true
        options.saysToolsChanged = true
        let (server, client) = try await home(options)
        defer { server.stop() }
        #expect(try await client.listTools().count == 10)
        let result = try await client.call("HassTurnOff", arguments: ["name": "Lampe du bureau"])
        #expect(!result.isError)
        #expect(server.isOn("Lampe du bureau") == false)
        // The stream also said the list of tools changed.
        #expect(await client.toolsChanged)
    }

    @Test func aFailureTheToolReportsIsAResult() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let result = try await client.call("HassTurnOn", arguments: ["area": "Garage"])
        #expect(result.isError)
        #expect(result.text == "Error calling tool: No area named Garage")
    }

    @Test func sendsTheTokenAndTellsARefusedOne() async throws {
        var options = FakeHomeAssistant.Options()
        options.token = "the-right-token"
        let (server, client) = try await home(options, token: "the-right-token")
        defer { server.stop() }
        #expect(try await client.listTools().count == 10)
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
        let turnOn = parameters("HassTurnOn")
        #expect(turnOn.map(\.name) == ["area", "device_class", "domain", "floor", "name"])
        #expect(turnOn[0].kind == .string)
        if case .strings(let classes) = turnOn[1].kind { #expect(classes.contains("shutter")) } else { Issue.record() }
        #expect(turnOn[2].kind == .strings([]))
        #expect(turnOn.allSatisfy { !$0.required })
        let climate = parameters("HassClimateSetTemperature")
        #expect(climate.first { $0.name == "temperature" }.map { ($0.kind, $0.required) } ?? (.string, false) == (.number, true))
        let light = parameters("HassLightSet")
        #expect(light.first { $0.name == "brightness" }?.kind == .integer)
        #expect(light.first { $0.name == "brightness" }?.description == "(0 to 100)")
        let todo = parameters("todo_get_items")
        #expect(todo.first { $0.name == "status" }?.kind == .oneOf(["needs_action", "completed", "all"]))
        #expect(parameters("GetLiveContext").isEmpty)
        // What the model sees of Home Assistant's intents: their targets described, without `device_class`.
        let offered = ConnectedTools.parameters(tools.first { $0.name == "HassTurnOn" }!)
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
        // What Maé has herself is off: lists, the date and time.
        #expect(settings.actions.filter { !$0.enabled }.map(\.name)
            == ["HassListAddItem", "HassListCompleteItem", "todo_get_items", "GetDateTime"])
        let specs = await tools.tools()
        #expect(specs.map(\.name) == ["HassTurnOn", "HassTurnOff", "HassSetPosition", "HassLightSet",
                                      "HassClimateSetTemperature", "GetLiveContext"])
        // Ask first: what acts waits for a "oui"; reading never does, even without annotations.
        #expect(await tools.risk(of: ToolCall(name: "HassTurnOn")) == .sensitive)
        #expect(await tools.risk(of: ToolCall(name: "GetLiveContext")) == .read)
        // The server's own words.
        #expect(specs.first?.description.hasPrefix("Turns on/opens/presses") == true)
        #expect(await tools.promptAddendum()?.contains("« Home Assistant »") == true)

        var direct = settings
        direct.whenActing = .doDirectly
        #expect(await tools.configure([ConnectedTools.Connection(settings: direct, client: client)]))
        #expect(await tools.risk(of: ToolCall(name: "HassTurnOn")) == .undoable)
        #expect(await tools.risk(of: ToolCall(name: "GetLiveContext")) == .read)
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

    @Test func namesStayUnique() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let mine = MCPTool(name: "minuteur", description: "A timer of its own", inputSchema: ["type": "object"])
        var first = ConnectedToolSettings(name: "Maison", address: server.address.absoluteString, access: .none)
        first.actions = [.init(tool: MCPTool(name: "HassTurnOn", description: "On"), enabled: true),
                         .init(tool: mine, enabled: true)]
        var second = ConnectedToolSettings(name: "Chalet", address: server.address.absoluteString, access: .none)
        second.actions = [.init(tool: MCPTool(name: "HassTurnOn", description: "On"), enabled: true)]
        let tools = ConnectedTools()
        await tools.configure([.init(settings: first, client: client), .init(settings: second, client: client)])
        #expect(await tools.tools().map(\.name) == ["HassTurnOn", "minuteur_2", "HassTurnOn_2"])
        // The second one's call reaches the service under its own name.
        _ = try await tools.perform(ToolCall(name: "HassTurnOn_2", arguments: ["area": "Salon"]), context: context)
        #expect(server.calls.map(\.name) == ["HassTurnOn"])
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
        var reply = await runner.handle(ToolCall(name: "HassTurnOn", arguments: ["area": "salon"]), context: context)
        #expect(reply.spoken == "J’allume le salon avec Home Assistant. On y va\(nb)?")
        #expect(await runner.interception(for: "non", now: now) == .decline)
        _ = await runner.resolve(.decline, context: context)
        #expect(server.calls.isEmpty)

        // Again, then « oui »: done, and the model says it from Home Assistant's answer.
        _ = await runner.handle(ToolCall(name: "HassTurnOn", arguments: ["area": "salon"]), context: context)
        reply = try #require(await runner.resolve(.confirm, context: context))
        #expect(server.calls.map(\.name) == ["HassTurnOn"])
        #expect(reply.modelSpeaks)
        #expect(reply.spoken == ConnectedToolPhrases.done)
        // "annule": MCP cannot undo.
        #expect(await runner.interception(for: "annule", now: now) == .undo)
        reply = try #require(await runner.resolve(.undo, context: context))
        #expect(reply.spoken == "Je ne peux pas défaire ce que j’ai demandé à Home Assistant.")

        // Reading never asks.
        reply = await runner.handle(ToolCall(name: "GetLiveContext"), context: context)
        #expect(reply.modelSpeaks)
        #expect(server.calls.map(\.name) == ["HassTurnOn", "GetLiveContext"])
        if case .object(let result) = reply.forModel, case .object(let read)? = result["résultat"] {
            #expect(read["result"]?.text?.contains("Plafonnier du salon") == true)
        } else {
            Issue.record("unexpected result: \(reply.forModel)")
        }

        // An answer that says it failed: told as a failure.
        _ = await runner.handle(ToolCall(name: "HassTurnOn", arguments: ["area": "Garage"]), context: context)
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
        _ = await runner.handle(ToolCall(name: "HassTurnOn", arguments: ["area": "salon"]), context: context)
        _ = await runner.handle(ToolCall(name: "HassTurnOn", arguments: ["area": "cuisine"]), context: context,
                                sameRequest: true)
        #expect(await runner.pendingQuestion(.french)
            == "J’allume le salon avec Home Assistant et j’allume la cuisine avec Home Assistant\(nb): on y va\(nb)?")
        let reply = try #require(await runner.resolve(.confirm, context: context))
        #expect(server.calls.map(\.name) == ["HassTurnOn", "HassTurnOn"])
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
        #expect(without.hasSuffix(" Exemples : à « Allume le couloir », ta réponse entière est <HassTurnOn area=couloir> ; "
            + "à « Ferme tous les volets », <HassTurnOff domain=[cover]>"))
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
        _ = try await tools.perform(ToolCall(name: "GetLiveContext", arguments: ["entity": "cuisine"]), context: context)
        _ = try await tools.perform(ToolCall(name: "HassTurnOn", arguments: ["area": "salon", "pièce": "salon"]), context: context)
        #expect(server.calls.map(\.arguments) == [[:], ["area": "salon"]])
        let open: JSONValue = ["type": "object", "properties": ["a": ["type": "string"]], "additionalProperties": true]
        #expect(ConnectedTools.declared(["a": "1", "b": "2"], open) == ["a": "1", "b": "2"])
        #expect(ConnectedTools.declared(["b": "2"], ["type": "object"]) == ["b": "2"])
    }

    @Test func doesItDirectlyWhenToldTo() async throws {
        let (server, client) = try await home()
        defer { server.stop() }
        let (tools, _) = try await connected(server, client, whenActing: .doDirectly)
        let runner = ToolRunner(providers: [tools], actions: false)
        _ = await runner.tools()
        let reply = await runner.handle(ToolCall(name: "HassTurnOff", arguments: ["domain": ["light"]]), context: context)
        #expect(server.calls.map(\.name) == ["HassTurnOff"])
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
        let outcome = try await tools.perform(ToolCall(name: "GetLiveContext"), context: context)
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
    }
}
