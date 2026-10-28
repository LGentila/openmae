import FakeHomeAssistant
import Foundation
import Testing

@testable import VoiceCore

/// The pretend Home Assistant as a connected tool just added (the switches a new tool starts with), with the names its
/// read and its turning on have for the model, whichever way Home Assistant lists them (`ConnectedTools.homeAssistantName`).
private func pretendHome() async throws -> (server: FakeHomeAssistant, tools: ConnectedTools, read: String, turnOn: String) {
    let server = FakeHomeAssistant()
    try await server.start()
    let client = MCPClient(address: server.address, token: nil)
    var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .none)
    settings.actions = settings.merging(try await client.listTools())
    let tools = ConnectedTools()
    await tools.configure([ConnectedTools.Connection(settings: settings, client: client)])
    let names = await tools.tools().map(\.name)
    let read = try #require(names.first { ConnectedTools.homeAssistantName($0) == "GetLiveContext" })
    let turnOn = try #require(names.first { ConnectedTools.homeAssistantName($0) == "HassTurnOn" })
    return (server, tools, read, turnOn)
}

private func waitFor(_ condition: () async -> Bool) async {
    for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite("Connected tools: a read after the model's own words", .serialized)
struct ConnectedToolsAfterWordsTests {
    /// A read written after words of the model's own is left out, with the actions or without them, unless the model gave
    /// a call a fair chance at its first token (`ConnectedTools.ignoresAfterWords`); a misspelled name is read as its
    /// tool's. An action that changes something, a built-in tool and an unknown name never are.
    @Test func aReadAfterWordsIsLeftOut() async throws {
        let home = try await pretendHome()
        defer { home.server.stop() }
        let meant = ConnectedTools.readMeantFrom
        for actions in [false, true] {
            let runner = ToolRunner(providers: [TimerTools(), home.tools], actions: actions)
            _ = await runner.tools()
            for chance in [nil, 0, meant / 2] as [Double?] {
                let label = "actions \(actions), chance \(chance ?? -1)"
                #expect(await runner.ignoresAfterWords(home.read, callChanceAtStart: chance), "\(label)")
                #expect(await runner.ignoresAfterWords(String(home.read.dropLast()), callChanceAtStart: chance), "\(label)")
                #expect(await !runner.ignoresAfterWords(home.turnOn, callChanceAtStart: chance), "\(label)")
                #expect(await !runner.ignoresAfterWords("minuteur", callChanceAtStart: chance), "\(label)")
            }
            #expect(await !runner.ignoresAfterWords(home.read, callChanceAtStart: meant))
            #expect(await !runner.ignoresAfterWords(home.read, callChanceAtStart: 0.9))
            #expect(await !runner.ignoresAfterWords("outil_inconnu", callChanceAtStart: 0))
        }
        // Another service's tool that says it only reads: the same.
        var notes = ConnectedToolSettings(name: "Notes", address: home.server.address.absoluteString, access: .none)
        notes.actions = [.init(tool: MCPTool(name: "search_notes", description: "Searches the notes.", readOnlyHint: true),
                               enabled: true),
                         .init(tool: MCPTool(name: "create_note", description: "Creates a note."), enabled: true)]
        let other = ConnectedTools()
        await other.configure([.init(settings: notes, client: MCPClient(address: home.server.address, token: nil))])
        #expect(await other.ignoresAfterWords("search_notes", actions: true, callChanceAtStart: 0))
        #expect(await !other.ignoresAfterWords("create_note", actions: true, callChanceAtStart: 0))
    }

    /// With the actions on and the waiting phrase on, as in the app: a read after an answer of the model's own, which gave
    /// a call little chance at its first token (« Merci beaucoup, c'est parfait » : « De rien, ravi que ça te
    /// convienne. », then the read), is left out: the user hears the answer alone, without the waiting phrase, nothing
    /// reaches Home Assistant, and the history keeps the answer without the call. When the model gave a call a fair chance
    /// at its first token (« Je vérifie ça pour toi. », then the read), the read is carried out and the model says what it
    /// found.
    @Test(arguments: [nil, ConnectedTools.readMeantFrom] as [Double?])
    func aReadAfterAnAnswerIsLeftOutInTheConversation(chance: Double?) async throws {
        let home = try await pretendHome()
        defer { home.server.stop() }
        let read = ToolCall(name: home.read)
        let answer = (chance ?? 0) < ConnectedTools.readMeantFrom ? "De rien, ravi que ça te convienne."
            : "Je vérifie ça pour toi."
        let found = "La lumière du salon est allumée."
        let model = ScriptedModel(scripts: [
            [.text(answer), .toolCallStarted, .toolCallNamed(read.name), .toolCall(read)],
            [.text(found)],
        ], callChanceAtStart: chance)
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: FakeSpeaker(),
                                     tools: ToolRunner(providers: [TimerTools(), home.tools], actions: true))
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await pipeline.submit(text: "Merci beaucoup, c'est parfait")
        guard (chance ?? 0) < ConnectedTools.readMeantFrom else {
            await waitFor { await log.pieces.contains(found) }
            #expect(await log.pieces.contains(found))
            #expect(home.server.calls.map(\.name) == [read.name])
            return
        }
        await waitFor { await !model.catchUps.isEmpty }  // the exchange recorded
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.pieces == [answer])
        #expect(home.server.calls.isEmpty)
        #expect(await model.requests.count == 1)  // nothing to sum up
        await pipeline.submit(text: "Bonne soirée")
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        #expect(history.allSatisfy { $0.toolCalls.isEmpty && $0.role != .tool })
        #expect(history.dropLast().last == ChatMessage(.assistant, answer))
    }
}
