import Foundation
import Testing

@testable import VoiceCore

// Several actions asked in one request: carried out in the order the model wrote them, at most
// `PipelineConfig.actionsPerRequest`; one second try for the refused ones; one question for the sensitive ones; one
// summing up of what came from outside; « annule » takes them all back.

private let paris = TimeZone(identifier: "Europe/Paris")!
/// Thursday 15 October 2026, 18:42 in Paris.
private let now = LocalDateTime.parse("2026-10-15T18:42", in: paris)!.date
private let nb = "\u{00A0}"

private func context(at date: Date = now) -> ToolContext {
    ToolContext(now: date, timeZone: paris, language: .french)
}

private func note(_ title: String?) -> ToolCall {
    ToolCall(name: "noter", arguments: title.map { ["titre": .string($0)] } ?? [:])
}

private func noted(_ title: String) -> String { "C’est noté\(nb): \(title)." }
/// The last of several confirmations in a row, linked to the one before.
private func andNoted(_ title: String) -> String { "Et c’est noté\(nb): \(title)." }

/// "envoyer" waits for a yes, and says what it would send.
actor SendingTools: ToolProvider {
    nonisolated let identifier = "sending"
    private(set) var sent: [String] = []
    private(set) var dropped: [String] = []

    func tools() -> [ToolSpec] {
        [ToolSpec(name: "envoyer", description: "Envoie.", parameters: [ToolParameter("quoi", .string, "Quoi.")],
                  risk: .sensitive)]
    }

    func summary(of call: ToolCall, context: ToolContext) -> String {
        "J’envoie «\(nb)\(call.text("quoi") ?? "")\(nb)». On y va\(nb)?"
    }

    func dropped(_ call: ToolCall) { dropped.append(call.text("quoi") ?? "") }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome {
        sent.append(call.text("quoi") ?? "")
        return ToolOutcome(spoken: "C’est envoyé\(nb): \(call.text("quoi") ?? "").", forModel: ["statut": "envoyé"])
    }
}

/// "allumer" is carried out at once, and cannot be taken back (as a shortcut).
actor LightTools: ToolProvider {
    nonisolated let identifier = "light"
    private(set) var lit = 0

    func tools() -> [ToolSpec] { [ToolSpec(name: "allumer", description: "Allume.", parameters: [], risk: .undoable)] }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome {
        lit += 1
        return ToolOutcome(spoken: "C’est fait, j’ai lancé «\(nb)Salon\(nb)».", forModel: ["statut": "fait"],
                           cannotUndo: ActionPhrases.cannotUndoShortcut(context.language))
    }
}

@Suite("Several actions: tool runner")
struct SeveralActionsRunnerTests {
    /// The sensitive calls of one request wait together: one question for them all, one "oui" carries them all out in
    /// order; a single one keeps its own sentence.
    @Test func sensitiveCallsOfARequestWaitForOneYes() async {
        let sending = SendingTools()
        let runner = ToolRunner(providers: [sending])
        _ = await runner.tools()
        let first = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "A"]), context: context())
        #expect(first.waitsForYes)
        #expect(await runner.pendingQuestion(.french) == "J’envoie «\(nb)A\(nb)». On y va\(nb)?")
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "B"]), context: context(), sameRequest: true)
        #expect(await runner.pendingQuestion(.french)
                == "J’envoie «\(nb)A\(nb)» et j’envoie «\(nb)B\(nb)»\(nb): on y va\(nb)?")
        #expect(await sending.sent.isEmpty)
        #expect(await runner.interception(for: "oui", now: now) == .confirm)
        let reply = await runner.resolve(.confirm, context: context())
        #expect(reply?.spoken == "C’est envoyé\(nb): A. Et c’est envoyé\(nb): B.")
        #expect(await sending.sent == ["A", "B"])
        #expect(await runner.interception(for: "oui", now: now) == nil)  // nothing waits any more
    }

    @Test func noDropsThemAll() async {
        let sending = SendingTools()
        let runner = ToolRunner(providers: [sending])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "A"]), context: context())
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "B"]), context: context(), sameRequest: true)
        let reply = await runner.resolve(.decline, context: context())
        #expect(reply?.spoken == ActionPhrases.declined(.french))
        #expect(await sending.dropped == ["A", "B"])
        #expect(await sending.sent.isEmpty)
    }

    /// One expiry for the request: two minutes after its first sensitive call, all of them are dropped.
    @Test func theyExpireTogether() async {
        let sending = SendingTools()
        let runner = ToolRunner(providers: [sending])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "A"]), context: context())
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "B"]),
                                context: context(at: now.addingTimeInterval(30)), sameRequest: true)
        #expect(await runner.interception(for: "oui", now: now.addingTimeInterval(100)) == .confirm)
        #expect(await runner.interception(for: "oui", now: now.addingTimeInterval(121)) == nil)
        #expect(await runner.resolve(.confirm, context: context(at: now.addingTimeInterval(121))) == nil)
        #expect(await sending.sent.isEmpty)
    }

    /// A new request replaces everything that waited, once, not at each of its calls.
    @Test func aNewRequestReplacesWhatWaited() async {
        let sending = SendingTools()
        let recording = RecordingTools()
        let runner = ToolRunner(providers: [sending, recording])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "A"]), context: context())
        _ = await runner.handle(note("Pain"), context: context(), sameRequest: true)
        #expect(await sending.dropped.isEmpty)  // the same request: A still waits
        _ = await runner.handle(note("Lait"), context: context())  // a new one
        #expect(await sending.dropped == ["A"])
        #expect(await runner.pendingQuestion(.french) == nil)
    }

    /// « annule » after a request that did several things: all of them, the last one first, in one sentence, then what
    /// cannot be taken back.
    @Test func cancelTakesBackTheWholeRequest() async throws {
        let (timers, recording, light) = (TimerTools(), RecordingTools(), LightTools())
        let runner = ToolRunner(providers: [timers, recording, light])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "minuteur", arguments: ["duree": "10 minutes"]), context: context())
        _ = await runner.handle(note("Pain"), context: context(), sameRequest: true)
        _ = await runner.handle(ToolCall(name: "allumer"), context: context(), sameRequest: true)
        #expect(await timers.count == 1)
        #expect(await runner.interception(for: "Annule.", now: now.addingTimeInterval(60)) == .undo)
        let reply = try #require(await runner.resolve(.undo, context: context(at: now.addingTimeInterval(60))))
        #expect(reply.spoken == "C’est annulé\(nb): le minuteur et le rappel. " + ActionPhrases.cannotUndoShortcut(.french))
        #expect(await timers.count == 0)
        #expect(await recording.undone == ["n1"])
        #expect(await runner.interception(for: "annule", now: now.addingTimeInterval(61)) == nil)
    }

    /// Only the last request's actions: those of the one before are not taken back with them.
    @Test func cancelTakesBackOnlyTheLastRequest() async throws {
        let recording = RecordingTools()
        let runner = ToolRunner(providers: [recording])
        _ = await runner.tools()
        _ = await runner.handle(note("Pain"), context: context())
        _ = await runner.handle(note("Lait"), context: context())
        _ = await runner.handle(note("Œufs"), context: context(), sameRequest: true)
        let reply = try #require(await runner.resolve(.undo, context: context()))
        #expect(reply.spoken == "C’est annulé\(nb): les deux rappels.")
        #expect(await recording.undone == ["n3", "n2"])
    }

    /// The actions carried out after the "oui" belong to the request that asked for them: « annule » takes them back
    /// with the others.
    @Test func cancelAfterYesTakesBackTheWholeRequest() async throws {
        let (sending, recording) = (SendingTools(), RecordingTools())
        let runner = ToolRunner(providers: [sending, recording])
        _ = await runner.tools()
        _ = await runner.handle(note("Pain"), context: context())
        _ = await runner.handle(ToolCall(name: "envoyer", arguments: ["quoi": "A"]), context: context(), sameRequest: true)
        _ = await runner.resolve(.confirm, context: context())
        let reply = try #require(await runner.resolve(.undo, context: context()))
        // "envoyer" has nothing to take back (no undo token): said after what was taken back.
        #expect(reply.spoken == ActionPhrases.undone(.reminder, .french) + " " + ActionPhrases.cannotUndo(.french))
        #expect(await recording.undone == ["n1"])
    }

    @Test func phrases() {
        #expect(ActionPhrases.atMost(3, .french) == "Je fais trois choses à la fois au plus\(nb): redis-moi la suite.")
        #expect(ActionPhrases.atMost(1, .french) == ActionPhrases.oneThingAtATime(.french))
        #expect(ActionPhrases.withoutQuestion(ActionPhrases.confirmShortcut(name: "Salon", .french))
                == "Je lance le raccourci «\(nb)Salon\(nb)»")
        #expect(ActionPhrases.withoutQuestion(AgentPhrases.review(agent: "Claude Code", title: "relire le README",
                                                                  folder: nil, .french))
                == "Je confie «\(nb)relire le README\(nb)» à Claude Code")
        #expect(ActionPhrases.withoutQuestion(ActionPhrases.confirmShortcut(name: "Salon", .english))
                == "I’ll run the shortcut “Salon”")
        #expect(ActionPhrases.undone(["le minuteur", "le minuteur", "l’événement"], .french)
                == "C’est annulé\(nb): les deux minuteurs et l’événement.")
        #expect(ActionPhrases.undone(["the timer", "the timer"], .english) == "Cancelled: I took back the two timers.")
        #expect(ActionPhrases.undone(["la tâche de Claude Code", "la tâche de Claude Code"], .french)
                == "C’est annulé\(nb): les deux tâches de Claude Code.")
    }

    /// « Et » before the last of several confirmations: the first word keeps its capital only when it has it for its own
    /// sake (a name, an English day or "I").
    @Test func linkingWord() {
        #expect(ActionPhrases.linked(ActionPhrases.timerStarted(seconds: 600, label: nil, .french), .french)
                == "Et c’est parti pour 10 minutes. Je te préviens à la fin.")
        #expect(ActionPhrases.linked(noted("Pain"), .french) == andNoted("Pain"))
        #expect(ActionPhrases.linked(AgentPhrases.started(.french), .french)
                == "Et c’est parti\(nb): tu auras une notification quand ce sera fini.")
        #expect(ActionPhrases.linked("Demain, tu as une seule chose\(nb): Dentiste à 10\(nb)h.", .french)
                == "Et demain, tu as une seule chose\(nb): Dentiste à 10\(nb)h.")
        #expect(ActionPhrases.linked("L'alarme du salon est réglée.", .french) == "Et l'alarme du salon est réglée.")
        #expect(ActionPhrases.linked(AgentPhrases.severalRunning(agent: "Claude Code", titles: ["A", "B"], .french),
                                     .french).hasPrefix("Et Claude Code travaille sur deux tâches"))
        #expect(ActionPhrases.linked("Noted: bread.", .english) == "And noted: bread.")
        #expect(ActionPhrases.linked(AgentPhrases.started(.english), .english)
                == "And it’s started: you’ll get a notification when it’s done.")
        #expect(ActionPhrases.linked("Friday, October 16, you have just one thing: Dentist.", .english)
                == "And Friday, October 16, you have just one thing: Dentist.")
        #expect(ActionPhrases.linked("I ran the shortcut.", .english) == "And I ran the shortcut.")
    }
}

/// "casser" fails when it is carried out (an error, not a refusal), as a calendar that cannot save.
private actor BrokenTools: ToolProvider {
    nonisolated let identifier = "broken"
    struct Broken: Error {}

    func tools() -> [ToolSpec] { [ToolSpec(name: "casser", description: "Casse.", parameters: [], risk: .undoable)] }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome { throw Broken() }
}

@Suite("Several actions: pipeline", .serialized)
struct SeveralActionsPipelineTests {
    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ sentences: [String], _ providers: [any ToolProvider], max: Int = 3,
              filler: Bool = false) -> (VoicePipeline, EventRecorder)
    {
        var config = PipelineConfig()
        config.toolCallFiller = filler
        config.actionsPerRequest = max
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: ScriptedTranscriber(sentences),
                                     model: model, synthesizer: FakeSynthesizer(), output: FakeSpeaker(),
                                     tools: ToolRunner(providers: providers), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        return (pipeline, log)
    }

    /// A turn: the user speaks, then waits for the end of the answer.
    func say(_ pipeline: VoicePipeline, _ log: EventRecorder) async {
        let before = await log.finished.count
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count > before }
        await waitFor { await log.states.last == .listening }
    }

    static let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]

    /// Two and three calls: carried out in the order written, each sentence said in that order; the model's limit set
    /// from the config; the history keeps one assistant message with every call, then their results in the same order,
    /// as the model wrote them.
    @Test(arguments: [2, 3])
    func callsAreCarriedOutInOrder(count: Int) async throws {
        let titles = Array(["Pain", "Lait", "Œufs"].prefix(count))
        let calls: [ModelOutput] = titles.flatMap { [ModelOutput.toolCallStarted, .toolCall(note($0))] }
        let (model, tools) = (ScriptedModel(scripts: [calls, Self.thanks]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le pain, le lait et les œufs", "Merci"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await model.callLimit == 3)
        #expect(await tools.performed.map { $0.text("titre") } == titles)
        // The last one linked to the one before: « … Et c’est noté : … ».
        let said = (titles.dropLast().map(noted) + [andNoted(titles.last!)]).joined(separator: " ")
        #expect(said == (count == 2 ? "C’est noté\(nb): Pain. Et c’est noté\(nb): Lait."
                         : "C’est noté\(nb): Pain. C’est noté\(nb): Lait. Et c’est noté\(nb): Œufs."))
        #expect(await log.pieces.joined(separator: " ") == said)
        #expect(await model.requests.count == 1)
        await say(pipeline, log)
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant] + Array(repeating: .tool, count: count)
                + [.assistant, .user])
        #expect(history[2].toolCalls == titles.map(note))
        #expect(history[3..<(3 + count)].map(\.toolResult) == (1...count).map { ["id": .string("n\($0)")] })
        #expect(history[3 + count].content == said)
    }

    /// More calls than the app carries out at once: the first ones, then « Je fais trois choses à la fois au plus »,
    /// once; whether the model wrote the fourth call (another model) or stopped before it (`moreToolCalls`).
    @Test(arguments: [false, true])
    func moreThanTheMaximum(fourthWritten: Bool) async throws {
        let titles = ["Pain", "Lait", "Œufs"]
        let calls: [ModelOutput] = titles.map { .toolCall(note($0)) }
            + [fourthWritten ? .toolCall(note("Beurre")) : .moreToolCalls]
        let (model, tools) = (ScriptedModel(scripts: [calls, Self.thanks]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le pain, le lait, les œufs et le beurre", "Merci"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == titles)
        let atMost = ActionPhrases.atMost(3, .french)
        #expect(atMost == "Je fais trois choses à la fois au plus\(nb): redis-moi la suite.")
        #expect(await log.pieces.joined(separator: " ")
                == [noted("Pain"), noted("Lait"), andNoted("Œufs"), atMost].joined(separator: " "))
        await say(pipeline, log)
        let history = try #require(await model.requests.last)
        #expect(history[2].toolCalls == titles.map(note))  // what was carried out, not the fourth
    }

    /// « Crée … puis décale-le »: the calls are carried out one after the other, so the change finds the item the
    /// creation just saved.
    @Test func laterCallSeesTheEarlierOne() async throws {
        let calls: [ModelOutput] = [
            .toolCall(ToolCall(name: "creer_evenement", arguments: ["titre": "Garagiste", "quand": "demain à 10 h"])),
            .toolCall(ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "quand": "à 11 h"])),
        ]
        let (model, calendar) = (ScriptedModel(scripts: [calls]), CheckedCalendar())
        let (pipeline, log) = make(model, ["Crée un rendez-vous demain à 10 h chez le garagiste, puis décale-le à 11 h"],
                                   [calendar])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await calendar.created.count == 1)
        #expect(await calendar.items["e1"]?.arguments["quand"] == "à 11 h")
        #expect(await log.pieces.joined(separator: " ")
                == "C’est dans ton agenda\(nb): Garagiste. Et c’est modifié\(nb): Garagiste.")
    }

    /// One call refused among two, and the model's second try corrects it: the valid one is carried out at once, the
    /// second try's request holds both results, and only the corrected call is carried out from it.
    @Test func oneRefusedAmongTwoIsCorrected() async throws {
        let first: [ModelOutput] = [.toolCall(note(nil)), .toolCall(note("Lait"))]
        let secondTry: [ModelOutput] = [.toolCall(note("Pain"))]
        let (model, tools) = (ScriptedModel(scripts: [first, secondTry, Self.thanks]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le pain et le lait", "Merci"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Lait", "Pain"])
        #expect(await log.pieces.joined(separator: " ") == noted("Lait") + " " + andNoted("Pain"))
        #expect(await model.requests.count == 2)
        let retry = try #require(await model.requests.last)
        #expect(retry.suffix(3).map(\.role) == [.assistant, .tool, .tool])
        #expect(retry.suffix(3).first?.toolCalls == [note(nil), note("Lait")])
        #expect(retry.last?.toolResult == ["id": "n1"])  // the result already obtained
        await say(pipeline, log)
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .tool, .tool, .assistant, .tool, .assistant, .user])
    }

    /// One call refused among two, and the model's second try says nothing: the valid one is carried out, then the app
    /// asks about the refused one.
    @Test func oneRefusedAmongTwoIsAskedAfterTheConfirmation() async throws {
        let first: [ModelOutput] = [.toolCall(note(nil)), .toolCall(note("Lait"))]
        let (model, tools) = (ScriptedModel(scripts: [first, []]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le pain et le lait"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Lait"])
        #expect(await log.pieces.joined(separator: " ") == noted("Lait") + " " + ActionPhrases.missingTitle(.french))
        #expect(await model.requests.count == 2)
    }

    /// A refusal the model cannot correct (a moment already gone): no second try, the valid call is carried out, and the
    /// question comes after its sentence.
    @Test func refusalWithoutSecondTryIsAskedAfterTheConfirmation() async throws {
        let first: [ModelOutput] = [
            .toolCall(ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": "hier à 15 h"])),
            .toolCall(ToolCall(name: "creer_rappel", arguments: ["titre": "Pain"])),
        ]
        let (model, calendar) = (ScriptedModel(scripts: [first]), CheckedCalendar())
        let (pipeline, log) = make(model, ["Ajoute le dentiste hier à 15 h et rappelle-moi le pain"], [calendar])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await calendar.created.map { $0.text("titre") } == ["Pain"])
        #expect(await log.pieces.joined(separator: " ") == "C’est noté\(nb): Pain. " + ActionPhrases.datePassed(.french))
        #expect(await model.requests.count == 1)
    }

    /// The last of the confirmations is linked to the one before; the question about a refused call, said after them,
    /// never is.
    @Test func questionAfterTheConfirmationsIsNotLinked() async throws {
        let first: [ModelOutput] = [
            .toolCall(ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": "hier à 15 h"])),
            .toolCall(ToolCall(name: "minuteur", arguments: ["duree": "10 minutes"])),
            .toolCall(ToolCall(name: "creer_rappel", arguments: ["titre": "Pain"])),
        ]
        let (model, calendar, timers) = (ScriptedModel(scripts: [first]), CheckedCalendar(), TimerTools())
        let (pipeline, log) = make(model, ["Ajoute le dentiste hier à 15 h, un minuteur de dix minutes et le pain",
                                           "Annule."], [calendar, timers])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await timers.count == 1)
        #expect(await calendar.created.map { $0.text("titre") } == ["Pain"])
        #expect(await log.pieces.joined(separator: " ")
                == "C’est parti pour 10 minutes. Je te préviens à la fin. Et c’est noté\(nb): Pain. "
                + ActionPhrases.datePassed(.french))
        await say(pipeline, log)  // « Annule. »: the timer does not go on after the test
        #expect(await timers.count == 0)
    }

    /// A failure is no confirmation: the confirmation after it is not linked to it (a question came between them).
    @Test func confirmationAfterAFailureIsNotLinked() async throws {
        let first: [ModelOutput] = [.toolCall(note("Pain")), .toolCall(ToolCall(name: "casser")), .toolCall(note("Lait"))]
        let (model, tools) = (ScriptedModel(scripts: [first]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le pain, casse tout et note le lait"], [tools, BrokenTools()])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain", "Lait"])
        #expect(await log.pieces.joined(separator: " ")
                == [noted("Pain"), ActionPhrases.saveFailed(.french), noted("Lait")].joined(separator: " "))
    }

    /// While a second try may still carry out a corrected call, the confirmations before it are not linked; the
    /// correction's is, when nothing was said between them.
    @Test func correctionFromTheSecondTryIsTheOneLinked() async throws {
        let first: [ModelOutput] = [.toolCall(note(nil)), .toolCall(note("Pain")), .toolCall(note("Lait"))]
        let secondTry: [ModelOutput] = [.toolCall(note("Pain")), .toolCall(note("Œufs"))]
        let (model, tools) = (ScriptedModel(scripts: [first, secondTry]), RecordingTools())
        let (pipeline, log) = make(model, ["Note les œufs, le pain et le lait"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain", "Lait", "Œufs"])
        #expect(await log.pieces.joined(separator: " ")
                == [noted("Pain"), noted("Lait"), andNoted("Œufs")].joined(separator: " "))
    }

    /// Words of the model's between two confirmations: the second one no longer follows the first, it is not linked.
    @Test func confirmationAfterTheModelsWordsIsNotLinked() async throws {
        let first: [ModelOutput] = [.toolCall(note(nil)), .toolCall(note("Pain"))]
        let secondTry: [ModelOutput] = [.text("Je note aussi le lait pour toi."), .toolCall(note("Lait"))]
        let (model, tools) = (ScriptedModel(scripts: [first, secondTry]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le lait et le pain"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain", "Lait"])
        #expect(await log.pieces.joined(separator: " ")
                == noted("Pain") + " Je note aussi le lait pour toi. " + noted("Lait"))
    }

    /// The second try writes again the call already carried out: it is not carried out twice, and the model reads why.
    @Test func secondTryDoesNotCarryOutACallTwice() async throws {
        let first: [ModelOutput] = [.toolCall(note("Lait")), .toolCall(note(nil))]
        let secondTry: [ModelOutput] = [.toolCall(note("Lait")), .toolCall(note("Pain"))]
        let (model, tools) = (ScriptedModel(scripts: [first, secondTry, Self.thanks]), RecordingTools())
        let (pipeline, log) = make(model, ["Note le lait et le pain", "Merci"], [tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Lait", "Pain"])
        await say(pipeline, log)
        let history = try #require(await model.requests.last)
        #expect(history[5].toolCalls == [note("Lait"), note("Pain")])
        #expect(history[6].toolResult == ["statut": .string(ToolOutcome.alreadyDone)])
        #expect(history[7].toolResult == ["id": "n2"])
    }

    /// An action and a sensitive one: the first carried out at once, the second waits; « oui » carries it out. Two
    /// sensitive ones: one question for both; « non » drops both.
    @Test(arguments: [true, false])
    func sensitiveCallsWaitForOneAnswer(yes: Bool) async throws {
        let first: [ModelOutput] = [.toolCall(note("Pain")), .toolCall(ToolCall(name: "envoyer", arguments: ["quoi": "A"])),
                                    .toolCall(ToolCall(name: "envoyer", arguments: ["quoi": "B"]))]
        let (model, tools, sending) = (ScriptedModel(scripts: [first]), RecordingTools(), SendingTools())
        let (pipeline, log) = make(model, ["Note le pain et envoie A et B", yes ? "Oui" : "Non"], [tools, sending])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.count == 1)
        #expect(await sending.sent.isEmpty)
        #expect(await log.pieces.joined(separator: " ")
                == noted("Pain") + " J’envoie «\(nb)A\(nb)» et j’envoie «\(nb)B\(nb)»\(nb): on y va\(nb)?")
        await say(pipeline, log)
        #expect(await sending.sent == (yes ? ["A", "B"] : []))
        #expect(await sending.dropped == (yes ? [] : ["A", "B"]))
        let answer = await log.finished.last?.assistantText
        #expect(answer == (yes ? "C’est envoyé\(nb): A. Et c’est envoyé\(nb): B." : ActionPhrases.declined(.french)))
        #expect(await model.requests.count == 1)  // the answer never reached the model
    }

    /// « Annule » right after a request with several actions takes them all back, without the model.
    @Test func cancelTakesBackTheWholeRequest() async throws {
        let first: [ModelOutput] = [.toolCall(ToolCall(name: "minuteur", arguments: ["duree": "10 minutes"])),
                                    .toolCall(note("Pain"))]
        let (model, tools, timers) = (ScriptedModel(scripts: [first]), RecordingTools(), TimerTools())
        let (pipeline, log) = make(model, ["Mets un minuteur de dix minutes et note le pain", "Annule."], [timers, tools])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await timers.count == 1)
        await say(pipeline, log)
        #expect(await timers.count == 0)
        #expect(await tools.undone == ["n1"])
        #expect(await log.pieces.last == "C’est annulé\(nb): le minuteur et le rappel.")
        #expect(await model.requests.count == 1)
    }

    /// A search with another action: the action's sentence first, then one pass where the model sums up the search's
    /// results. A call it writes then is never carried out.
    @Test func searchIsSummedUpAfterTheOtherAction() async throws {
        let first: [ModelOutput] = [.toolCall(ToolCall(name: "chercher", arguments: ["requete": "météo demain Paris"])),
                                    .toolCall(note("Pain"))]
        let summary: [ModelOutput] = [.text("Demain, il fera beau à Paris."), .toolCall(note("Parapluie"))]
        let (model, tools, search) = (ScriptedModel(scripts: [first, summary, Self.thanks]), RecordingTools(),
                                      SummedSearch())
        let (pipeline, log) = make(model, ["Cherche la météo de demain et note le pain", "Merci"], [tools, search])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await search.queries == ["météo demain Paris"])
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain"])  // not the call written while summing up
        #expect(await log.pieces.joined(separator: " ") == noted("Pain") + " Demain, il fera beau à Paris.")
        #expect(await model.requests.count == 2)
        let summing = try #require(await model.requests.last)
        #expect(summing.suffix(3).map(\.role) == [.assistant, .tool, .tool])
    }

    /// Summing up, the model writes calls and nothing else: none is carried out, it is told so and sums up once more.
    @Test func noCallIsCarriedOutWhileSummingUp() async throws {
        let first: [ModelOutput] = [.toolCall(note("Pain")),
                                    .toolCall(ToolCall(name: "chercher", arguments: ["requete": "météo"]))]
        let callsOnly: [ModelOutput] = [.toolCall(note("Lait")), .toolCall(note("Œufs"))]
        let (model, tools, search) = (ScriptedModel(scripts: [first, callsOnly, []]), RecordingTools(), SummedSearch())
        let (pipeline, log) = make(model, ["Note le pain et cherche la météo"], [tools, search])
        try await pipeline.start()
        await say(pipeline, log)
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain"])
        #expect(await model.requests.count == 3)
        let again = try #require(await model.requests.last)
        #expect(again.suffix(3).first?.toolCalls == [note("Lait"), note("Œufs")])
        #expect(again.last?.toolResult == ["erreur": .string(ToolOutcome.noCallWhileSummingUp)])
        #expect(await log.pieces.joined(separator: " ") == noted("Pain") + " " + SummedSearch.fallback)
    }

    /// A speculative turn dropped (the user went on speaking) carries out none of its calls.
    @Test func droppedSpeculativeTurnCarriesOutNothing() async throws {
        let calls: [ModelOutput] = [.toolCall(note("Pain")), .toolCall(note("Lait"))]
        let (model, tools) = (ScriptedModel(scripts: [calls]), RecordingTools())
        let (pipeline, _) = make(model, ["Note le pain et le lait"], [tools])
        try await pipeline.start()
        await push(pipeline, "1111111111" + "00000000")  // a pause: prepared speculatively, the calls written
        try await Task.sleep(for: .milliseconds(150))
        #expect(await tools.performed.isEmpty)
        await push(pipeline, "11111")  // the user goes on: the speculative turn and its calls are dropped
        try await Task.sleep(for: .milliseconds(100))
        #expect(await tools.performed.isEmpty)
        await push(pipeline, String(repeating: "0", count: 20))
        await waitFor { await tools.performed.count == 2 }
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain", "Lait"])
    }

    /// The first call is carried out, and its sentence said, while the model still writes the next one.
    @Test func firstActionDoesNotWaitForTheNextCall() async throws {
        let model = SlowSecondCall()
        let tools = RecordingTools()
        var config = PipelineConfig()
        config.toolCallFiller = false
        config.actionsPerRequest = 3
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: ScriptedTranscriber(["Pain et lait"]),
                                     model: model, synthesizer: FakeSynthesizer(), output: FakeSpeaker(),
                                     tools: ToolRunner(providers: [tools]), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.contains(noted("Pain")) }
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain"])
        #expect(await log.finished.isEmpty)  // the second call is not written yet
        await waitFor { await log.finished.count == 1 }
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain", "Lait"])
        #expect(await log.finished.first?.firstConfirmationMs != nil)
    }
}

/// Writes a first call at once, then starts the second one (as `MLXChatModel` reports the next call's start a token after
/// the first call's end), which it ends 400 ms later.
private actor SlowSecondCall: LanguageModel {
    nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.toolCall(note("Pain")))
                continuation.yield(.toolCallStarted)
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { continuation.yield(.toolCall(note("Lait"))) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}
