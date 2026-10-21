// voice-cli connected-tools — a conversation with a pretend Home Assistant connected (FakeHomeAssistant), in typed
// turns through the whole pipeline as in the app (the voice speaks into a silent speaker): what Maé says before
// "On y va ?", the user's "oui" and "non", what reaches the service, its log, then the same with "Do it directly".
//
//   voice-cli connected-tools [--tier minimum|standard|comfort] [--actions] [--do-directly] [--repeats 1]
//   voice-cli connected-tools --long-result [--tier minimum|standard|comfort] [--repeats 3]
//
// Without --actions, the connected tool is offered on its own, as in the app with the actions off; with it, after the
// app's actions (the calendar and reminders kept in memory, the timers running in voice-cli, as `--actions` gives them).
// --do-directly: only the "Do it directly" part. Each step is checked: ✓ or ✗.
//
// --long-result: no voice; the time of the answer after Home Assistant's `GetLiveContext` (« Quels appareils sont
// allumés ? ») as the app has it (the model writes its call, then reads the result and answers), for the pretend house as
// it is and with 200 more devices (the result cut at `ConnectedTools.resultLimit`).

import FakeHomeAssistant
import Foundation
import VoiceCore
import VoiceEngineApple

/// The connected tools' reports, kept in order.
private actor Reports {
    var entries: [ConnectedToolLogEntry] = []
    func add(_ report: ConnectedToolReport) {
        if case .log(_, let entry) = report { entries.append(entry) }
    }
}

func runConnectedToolsDialogue(_ o: Options) async throws {
    let server = FakeHomeAssistant()
    try await server.start()
    defer { server.stop() }
    let client = MCPClient(address: server.address, token: nil)
    var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .none)
    settings.actions = settings.merging(try await client.listTools())
    let provider = ConnectedTools()
    let reports = Reports()
    await provider.observe { report in Task { await reports.add(report) } }
    let actions: [any ToolProvider] = o.actions
        ? [MemoryCalendar(movingItems: ActionCatalog.movesItems(on: try tierOption(o))), TimerTools()] : []
    func runner(_ whenActing: ConnectedToolSettings.WhenActing) async -> ToolRunner {
        var tool = settings
        tool.whenActing = whenActing
        await provider.configure([ConnectedTools.Connection(settings: tool, client: client)])
        return ToolRunner(providers: actions + [provider], actions: o.actions)
    }
    let e = try await buildEngine(o, tools: await runner(o.doDirectly ? .doDirectly : .askFirst))
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    var checks: [(String, Bool)] = []

    /// One typed turn: what Maé said, the calls that reached the service, the new lines of the log.
    func turn(_ text: String) async -> (said: String, calls: [FakeHomeAssistant.Call], log: [ConnectedToolLogEntry]) {
        let calls = server.calls.count
        let lines = await reports.entries.count
        await mic.silence(0.5)
        let before = await e.log.completedTurns
        await e.pipeline.submit(text: text)
        await waitForAnswer(e, mic: mic, after: before, timeout: 90)
        await mic.silence(0.3)
        let said = await e.log.turns.last?.assistantText ?? ""
        let made = Array(server.calls.dropFirst(calls))
        let log = Array(await reports.entries.dropFirst(lines))
        print("■ « \(text) »\n    Maé: \(said)")
        for call in made { print("    → Home Assistant: \(call.name) \(call.arguments)") }
        for line in log { print("    log: \(line.title) — \(line.result)") }
        return (said, made, log)
    }
    func check(_ what: String, _ ok: Bool) {
        checks.append((what, ok))
        print("    \(ok ? "✓" : "✗") \(what)")
    }

    for round in 1...(o.repeats ?? 1) {
        if round > 1 { try await e.pipeline.resetConversation() }
        if !o.doDirectly {
            print("\n=== Ask first (round \(round)) ===")
            var t = await turn("Allume le salon")
            check("« Allume le salon »: says what she will do and asks, calls nothing",
                  t.said.contains("On y va") && t.calls.isEmpty)
            t = await turn("Oui")
            check("« Oui »: HassTurnOn is called and she says the result",
                  t.calls.map(\.name) == ["HassTurnOn"] && !t.said.isEmpty && !t.said.contains("On y va")
                      && t.log.map(\.result) == [.done])
            t = await turn("Éteins toutes les lumières")
            check("« Éteins toutes les lumières »: asks, calls nothing", t.said.contains("On y va") && t.calls.isEmpty)
            t = await turn("Non")
            check("« Non »: nothing is called, the log says « Refused by you »",
                  t.calls.isEmpty && t.log.map(\.result) == [.refusedByUser])
            t = await turn("Est-ce que la lumière de la cuisine est allumée ?")
            check("a question that only reads is answered without a « oui »",
                  t.calls.map(\.name) == ["GetLiveContext"] && !t.said.contains("On y va") && !t.said.isEmpty)
        }
        print("\n=== Do it directly (round \(round)) ===")
        try await e.pipeline.setTools(await runner(.doDirectly))
        var t = await turn("Éteins la lumière du salon")
        check("« Éteins la lumière du salon »: carried out at once",
              t.calls.map(\.name) == ["HassTurnOff"] && !t.said.contains("On y va"))
        t = await turn("Annule")
        check("« Annule »: says it cannot be undone, calls nothing", t.calls.isEmpty && t.said.contains("défaire"))
        if !o.doDirectly { try await e.pipeline.setTools(await runner(.askFirst)) }
    }
    let passed = checks.filter(\.1).count
    print("\n=== \(passed) of \(checks.count) checks passed ===")
    for (what, ok) in checks where !ok { print("✗ \(what)") }
}

/// --long-result (see the top of this file).
func measureLongResult(_ o: Options) async throws {
    let tier = try tierOption(o)
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    let model = try await MLXChatModel.load(directory: folder)
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue))")
    let clock = ContinuousClock()
    for extra in [0, 200] {
        var options = FakeHomeAssistant.Options()
        options.extraDevices = extra
        let server = FakeHomeAssistant(options: options)
        try await server.start()
        defer { server.stop() }
        let client = MCPClient(address: server.address, token: nil)
        var settings = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .none)
        settings.actions = settings.merging(try await client.listTools())
        let provider = ConnectedTools()
        await provider.configure([ConnectedTools.Connection(settings: settings, client: client)])
        await model.useTools(await provider.tools())
        var conversation = Conversation()
        // As the app has it with the actions off: that they are off and what the date line is, then the tool's part.
        conversation.systemAddenda = [ActionCatalog.partWithoutActions] + [await provider.promptAddendum()].compactMap { $0 }
        try await model.prefillBeginning(conversation.beginning)
        let now = Date()
        let request = conversation.messages(adding: Conversation.userMessage(
            "Quels appareils sont allumés ?", language: .french, dateLine: ActionCatalog.dateLine(now, timeZone: .current)))
        var firsts: [Double] = []
        var totals: [Double] = []
        var tokens = 0
        var characters = 0
        for _ in 1...(o.repeats ?? 3) {
            var made: ToolCall?
            for try await output in model.reply(to: request) {
                if case .toolCall(let call) = output, made == nil { made = call }
            }
            guard let call = made else {
                print("  the model wrote no call")
                continue
            }
            let outcome = try await provider.perform(call, context: ToolContext(now: now, language: .french))
            if case .object(let result) = outcome.forModel { characters = result.values.first?.text?.count ?? 0 }
            let called = request + [.call(call)]
            tokens = try await model.tokenCount(called + [.result(of: call, outcome.forModel)]) - model.tokenCount(called)
            let start = clock.now
            var first: Double?
            var said = ""
            for try await output in model.reply(to: called + [.result(of: call, outcome.forModel)]) {
                if case .text(let piece) = output {
                    if first == nil, piece.contains(where: \.isLetter) {
                        let d = clock.now - start
                        first = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                    }
                    said += piece
                }
            }
            let d = clock.now - start
            totals.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            if let first { firsts.append(first) }
            print("  \(call.name): “\(said.prefix(90).replacingOccurrences(of: "\n", with: " "))”")
            try await model.prefillBeginning(conversation.beginning)
        }
        print(String(format: "%@: result of %d characters (%d tokens): first words after it, median %.0f ms (%@); "
                     + "whole answer median %.0f ms",
                     extra == 0 ? "the house as it is" : "200 more devices", characters, tokens, median(firsts) ?? 0,
                     firsts.map { String(format: "%.0f", $0) }.joined(separator: ", "), median(totals) ?? 0))
    }
}
