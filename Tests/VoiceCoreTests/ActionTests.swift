import Foundation
import Testing

@testable import VoiceCore

private let paris = TimeZone(identifier: "Europe/Paris")!
/// Thursday 15 October 2026, 18:42 in Paris.
private let now = LocalDateTime.parse("2026-10-15T18:42", in: paris)!.date
private let nb = "\u{00A0}"

private func context(_ language: SpeechLanguage = .french, at date: Date = now) -> ToolContext {
    ToolContext(now: date, timeZone: paris, language: language)
}

private func date(_ text: String) -> Date { LocalDateTime.parse(text, in: paris)!.date }

@Suite("Action dates and sentences")
struct ActionPhraseTests {
    @Test func readsLocalDates() throws {
        let full = try #require(LocalDateTime.parse("2026-10-16T10:00", in: paris))
        #expect(full.hasTime)
        #expect(LocalDateTime.format(full.date, in: paris) == "2026-10-16T10:00")
        #expect(LocalDateTime.parse("2026-10-16", in: paris)?.hasTime == false)
        #expect(LocalDateTime.parse("2026-10-16T10:00:00Z", in: paris)?.date == full.date)  // the suffix is ignored
        #expect(LocalDateTime.parse("2026-02-30T10:00", in: paris) == nil)
        #expect(LocalDateTime.parse("demain 10h", in: paris) == nil)
    }

    @Test func refusesDatesInThePastOrTooFar() {
        func check(_ value: String) throws {
            _ = try DateCheck.upcoming(ToolCall(name: "x", arguments: ["d": .string(value)]), "d", context: context(),
                                       required: true)
        }
        #expect(throws: Never.self) { try check("2026-10-15T19:00") }
        #expect(throws: Never.self) { try check("2026-10-15") }  // today, no time
        #expect(throws: ToolRefusal.self) { try check("2026-10-15T09:00") }
        #expect(throws: ToolRefusal.self) { try check("2027-11-01T09:00") }
        #expect(throws: ToolRefusal.self) { try check("jeudi") }
        #expect(throws: ToolRefusal.self) {
            _ = try DateCheck.upcoming(ToolCall(name: "x"), "d", context: context(), required: true)
        }
    }

    @Test func saysDatesInFull() {
        let c = context()
        #expect(ActionPhrases.moment(date("2026-10-16T10:00"), hasTime: true, c) == "vendredi 16 octobre à 10\(nb)h")
        #expect(ActionPhrases.moment(date("2026-11-01T10:30"), hasTime: true, c) == "dimanche 1er novembre à 10\(nb)h\(nb)30")
        #expect(ActionPhrases.time(date("2026-10-16T03:00"), c) == "3\(nb)h du matin")
        #expect(ActionPhrases.time(date("2026-10-16T12:00"), c) == "midi")
        #expect(ActionPhrases.day(date("2027-01-04T10:00"), c) == "lundi 4 janvier 2027")  // not this year
        #expect(ActionPhrases.moment(date("2026-10-16T15:00"), hasTime: true, context(.english))
                == "Friday, October 16 at 3\(nb)PM")
    }

    @Test func confirmsWhatWasSaved() {
        let c = context()
        #expect(ActionPhrases.eventCreated(title: "Rendez-vous chez le médecin", start: date("2026-10-16T15:00"),
                                           end: date("2026-10-16T16:00"), allDay: false, calendarName: nil, c)
                == "C’est dans ton agenda\(nb): Rendez-vous chez le médecin, vendredi 16 octobre de 15\(nb)h à 16\(nb)h.")
        #expect(ActionPhrases.reminderCreated(title: "prendre rendez-vous chez le médecin", due: date("2026-10-16T10:00"),
                                              hasTime: true, listName: nil, c)
                == "C’est noté\(nb): vendredi 16 octobre à 10\(nb)h, prendre rendez-vous chez le médecin.")
        #expect(ActionPhrases.eventCreated(title: "Vacances", start: date("2026-12-20"), end: date("2026-12-25"),
                                           allDay: true, calendarName: "Maison", c)
                == "C’est dans ton calendrier «\(nb)Maison\(nb)»\(nb): Vacances, du dimanche 20 décembre au jeudi 24 décembre.")
    }

    @Test func readsAtMostFourItems() {
        let c = context()
        let items = (8...13).map { ActionPhrases.Item(title: "Point \($0)", date: date("2026-10-16T\($0):00"), hasTime: true) }
        let text = ActionPhrases.agenda(items, from: date("2026-10-16"), to: date("2026-10-17"), c)
        #expect(text == "Demain, tu as six choses\(nb): Point 8 à 8\(nb)h, Point 9 à 9\(nb)h, Point 10 à 10\(nb)h, "
                + "Point 11 à 11\(nb)h et deux autres.")
        #expect(ActionPhrases.agenda([], from: date("2026-10-15"), to: date("2026-10-16"), c)
                == "Aujourd’hui, rien de prévu dans ton agenda.")
        #expect(ActionPhrases.reminders([ActionPhrases.Item(title: "Pain", date: nil, hasTime: false)], from: nil, to: nil, c)
                == "Tu as un seul rappel\(nb): Pain.")
        // Today: a reminder without a time is said by its title; one left over from yesterday is only counted,
        // or read with its day when nothing is due today.
        let today = [ActionPhrases.Item(title: "Facture", date: date("2026-10-14T10:00"), hasTime: true),
                     ActionPhrases.Item(title: "Pain", date: date("2026-10-15"), hasTime: false),
                     ActionPhrases.Item(title: "Linge", date: date("2026-10-15T20:00"), hasTime: true)]
        #expect(ActionPhrases.reminders(today, from: now, to: date("2026-10-16"), c)
                == "Tu as deux rappels pour aujourd’hui\(nb): Pain et Linge à 20\(nb)h, plus un en retard.")
        #expect(ActionPhrases.reminders(Array(today.prefix(1)), from: now, to: date("2026-10-16"), c)
                == "Rien de prévu pour aujourd’hui, mais un rappel en retard\(nb): Facture le mercredi 14 octobre à 10\(nb)h.")
    }

    /// The voice renders texts of fewer than five words as silence.
    @Test func everyFixedSentenceHasFiveWords() {
        for language in SpeechLanguage.allCases {
            let sentences = [
                ActionPhrases.oneMoment(language), ActionPhrases.declined(language), ActionPhrases.cannotUndo(language),
                ActionPhrases.cannotUndoShortcut(language), ActionPhrases.oneThingAtATime(language),
                ActionPhrases.badTime(language), ActionPhrases.datePassed(language), ActionPhrases.dateTooFar(language),
                ActionPhrases.badDuration(language), ActionPhrases.missingTitle(language),
                ActionPhrases.nothingToChange(language), ActionPhrases.notUnderstood(language),
                ActionPhrases.saveFailed(language), ActionPhrases.undone(.event, language),
                ActionPhrases.undone(.reminder, language), ActionPhrases.undone(.change, language),
                ActionPhrases.undone(.timer, language), ActionPhrases.askingAccess(.calendar, language),
                ActionPhrases.deleted(event: true, title: "Yoga", language),
                ActionPhrases.timerStarted(seconds: 60, label: nil, language),
                ActionPhrases.timerFinished(seconds: 60, label: nil, language),
                ActionPhrases.shortcutDone(name: "Salon", output: nil, language),
                ActionPhrases.confirmShortcut(name: "Salon", language),
            ]
            for sentence in sentences {
                #expect(ActionPhrases.wordCount(SpeakableText.forVoice(sentence, language: language)) >= 5, "\(sentence)")
            }
        }
    }

    @Test func voiceReadsTimesInWords() {
        #expect(SpeakableText.forVoice("jeudi à 10\(nb)h\(nb)30, puis 1\(nb)h et 21h", language: .french)
                == "jeudi à 10 heures 30, puis 1 heure et 21 heures")
        #expect(SpeakableText.forVoice("j’ai lancé «\(nb)Salon\(nb)».", language: .french) == "j'ai lancé Salon.")
        #expect(SpeakableText.forVoice("about 10\(nb)h", language: .english) == "about 10 h")
    }

    @Test func copiedDateLineIsNotSpoken() {
        #expect(SpeakableText.clean("Il est dix-huit heures. (2026-10-15T18:42)") == "Il est dix-huit heures.")
        #expect(SpeakableText.clean("Bonne idée [2026-10-15 18:42] !") == "Bonne idée !")
    }

    @Test func durations() {
        #expect(ActionPhrases.duration(seconds: 600, .french) == "10 minutes")
        #expect(ActionPhrases.duration(seconds: 4500, .french) == "1 heure et 15 minutes")
        #expect(ActionPhrases.duration(seconds: 90, .english) == "1 minute and 30 seconds")
    }
}

@Suite("Action calls")
struct ActionCallTests {
    @Test func eventLastsAnHourByDefault() throws {
        let call = ToolCall(name: "creer_evenement", arguments: ["titre": "Yoga", "debut": "2026-10-16T18:00"])
        let times = try ActionCatalog.eventTimes(call, context: context())
        #expect(times.end.timeIntervalSince(times.start) == 3600)
        #expect(!times.allDay)
        let long = ToolCall(name: "creer_evenement", arguments: ["titre": "Yoga", "debut": "2026-10-16T18:00",
                                                                 "duree_minutes": "90"])
        #expect(try ActionCatalog.eventTimes(long, context: context()).end == date("2026-10-16T19:30"))
        let day = ToolCall(name: "creer_evenement", arguments: ["titre": "Anniversaire", "debut": "2026-11-03"])
        #expect(try ActionCatalog.eventTimes(day, context: context()).allDay)
    }

    @Test func emptyTitleOrUnknownShortcutIsRefused() {
        #expect(throws: ToolRefusal.self) {
            try ActionCatalog.check(ToolCall(name: "creer_rappel", arguments: ["titre": " "]), context: context())
        }
        #expect(throws: ToolRefusal.self) {
            try ActionCatalog.check(ToolCall(name: "lancer_raccourci", arguments: ["nom": "Inconnu"]), context: context(),
                                    shortcuts: ["Salon"])
        }
        #expect(throws: Never.self) {
            try ActionCatalog.check(ToolCall(name: "minuteur", arguments: ["duree_secondes": 600]), context: context())
        }
    }

    @Test func recognizesShortAnswers() {
        #expect(ReplyMatcher.confirmation("Oui, vas-y !") == .yes)
        #expect(ReplyMatcher.confirmation("Euh… d’accord.") == .yes)
        #expect(ReplyMatcher.confirmation("Non merci.") == .no)
        #expect(ReplyMatcher.confirmation("Laisse tomber") == .no)
        #expect(ReplyMatcher.confirmation("Oui mais d’abord dis-moi l’heure") == nil)
        #expect(ReplyMatcher.isCancel("Annule !"))
        #expect(ReplyMatcher.isCancel("Annule ça, s’il te plaît"))
        #expect(ReplyMatcher.isCancel("À nul."))  // how speech recognition heard it in a real test
        #expect(!ReplyMatcher.isCancel("Annule mon rendez-vous de lundi"))  // not in the list: the model handles it
        #expect(!ReplyMatcher.isCancel("Rappelle-moi ce que tu disais"))
    }

    @Test func olderSettingsStayReadable() throws {
        let old = #"{"audioMode":"headphones","pushToTalk":true}"#
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(old.utf8))
        #expect(settings.audioMode == .headphones && settings.pushToTalk)
        #expect(!settings.actionsEnabled && settings.shortcutsToConfirm.isEmpty)
    }

    @Test func historyDropsAnExchangeWithItsToolCall() {
        var c = Conversation(systemPrompt: "S")
        let call = ToolCall(name: "creer_rappel", arguments: ["titre": "Pain"])
        c.record(user: ChatMessage(.user, "Rappelle-moi le pain"), steps: [.call(call), .result(of: call, ["id": "r1"])],
                 assistant: "C’est noté.", interrupted: false)
        c.record(user: "Merci", language: .french, assistant: "Avec plaisir.", interrupted: false)
        #expect(c.messages.count == 7)
        c.dropOldestExchange()
        #expect(c.messages.map(\.content) == ["S", "Merci", "Avec plaisir."])
    }

    @Test func dateLineNamesTheDay() {
        #expect(ActionCatalog.dateLine(now, timeZone: paris) == "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)")
    }
}

// MARK: - Runner and pipeline

/// Records what it is asked to do. "noter" is undoable, "lancer" needs a yes.
actor RecordingTools: ToolProvider {
    nonisolated let identifier = "test"
    private(set) var performed: [ToolCall] = []
    private(set) var undone: [String] = []

    func tools() -> [ToolSpec] {
        [ToolSpec(name: "noter", description: "Note.", parameters: [ToolParameter("titre", .string, "Quoi.", required: true)],
                  risk: .undoable),
         ToolSpec(name: "lancer", description: "Lance.", parameters: [], risk: .sensitive)]
    }

    func check(_ call: ToolCall, context: ToolContext) throws {
        if call.name == "noter", call.text("titre") == nil {
            throw ToolRefusal(forModel: "Il manque « titre ».", spoken: ActionPhrases.missingTitle(context.language))
        }
    }

    func summary(of call: ToolCall, context: ToolContext) -> String { "Je lance le test. On y va ?" }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome {
        performed.append(call)
        return ToolOutcome(spoken: "C’est noté\(nb): \(call.text("titre") ?? "le test est lancé").",
                           forModel: ["id": .string("n\(performed.count)")],
                           undo: UndoToken(provider: identifier, id: "n\(performed.count)"))
    }

    func undo(_ token: UndoToken, context: ToolContext) -> String {
        undone.append(token.id)
        return ActionPhrases.undone(.reminder, context.language)
    }
}

@Suite("Tool runner")
struct ToolRunnerTests {
    @Test func sensitiveActionWaitsForYes() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        let asked = await runner.handle(ToolCall(name: "lancer"), context: context())
        #expect(asked.spoken.hasSuffix("On y va ?"))
        #expect(await tools.performed.isEmpty)
        #expect(await runner.interception(for: "Quelle heure est-il ?", now: now) == nil)  // still waiting
        #expect(await runner.interception(for: "oui", now: now) == .confirm)
        _ = await runner.resolve(.confirm, context: context())
        #expect(await tools.performed.count == 1)
        #expect(await runner.interception(for: "oui", now: now) == nil)  // nothing waits any more
    }

    @Test func noOrTimeDropsTheAction() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "lancer"), context: context())
        let reply = await runner.resolve(.decline, context: context())
        #expect(reply?.spoken == ActionPhrases.declined(.french))
        _ = await runner.handle(ToolCall(name: "lancer"), context: context())
        #expect(await runner.interception(for: "oui", now: now.addingTimeInterval(121)) == nil)  // expired
        #expect(await tools.performed.isEmpty)
    }

    @Test func cancelUndoesTheLastActionForTwoMinutes() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "noter", arguments: ["titre": "Pain"]), context: context())
        #expect(await runner.interception(for: "annule", now: now.addingTimeInterval(130)) == nil)
        #expect(await runner.interception(for: "Annule !", now: now.addingTimeInterval(60)) == .undo)
        let reply = await runner.resolve(.undo, context: context(at: now.addingTimeInterval(60)))
        #expect(reply?.spoken == ActionPhrases.undone(.reminder, .french))
        #expect(await tools.undone == ["n1"])
        #expect(await runner.interception(for: "annule", now: now.addingTimeInterval(61)) == nil)
    }

    @Test func refusedCallCanBeCorrected() async {
        let runner = ToolRunner(providers: [RecordingTools()])
        _ = await runner.tools()
        let reply = await runner.handle(ToolCall(name: "noter"), context: context())
        #expect(reply.retryable)
        #expect(reply.spoken == ActionPhrases.missingTitle(.french))
    }
}

/// Returns the given sentences, one per turn.
actor ScriptedTranscriber: Transcriber {
    private var sentences: [String]
    init(_ sentences: [String]) { self.sentences = sentences }
    func transcribe(_ samples: [Float]) async throws -> String {
        sentences.count > 1 ? sentences.removeFirst() : sentences[0]
    }
}

@Suite("Pipeline with actions", .serialized)
struct PipelineActionTests {
    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ transcriber: any Transcriber, _ speaker: FakeSpeaker, _ tools: RecordingTools,
              filler: Bool = false) -> VoicePipeline
    {
        var config = PipelineConfig()
        config.toolCallFiller = filler
        return VoicePipeline(detector: LoudnessDetector(), transcriber: transcriber, model: model,
                             synthesizer: FakeSynthesizer(), output: speaker, tools: ToolRunner(providers: [tools]),
                             config: config)
    }

    static let note: [ModelOutput] = [.toolCallStarted, .toolCall(ToolCall(name: "noter", arguments: ["titre": "Pain"]))]

    @Test func actionWaitsForTheEndOfTheTurn() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain"]), speaker, tools)
        try await pipeline.start()
        #expect(await model.tools.map(\.name) == ["noter", "lancer"])
        // A pause: the answer is prepared speculatively, the call is written… and must wait.
        await push(pipeline, "1111111111" + "00000000")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await tools.performed.isEmpty)
        await push(pipeline, "11111")  // the user goes on: the speculative turn and its call are dropped
        try await Task.sleep(for: .milliseconds(50))
        #expect(await tools.performed.isEmpty)
        await push(pipeline, String(repeating: "0", count: 20))  // the turn is over
        await waitFor { await speaker.played > 0 }
        #expect(await tools.performed.count == 1)
        let request = try #require(await model.requests.last)
        #expect(request.last?.content.contains("\n(Nous sommes le ") == true)  // the date line ends the message
    }

    @Test func oneActionPerTurnAndHistoryKeepsTheCall() async throws {
        let two = Self.note + [.toolCall(ToolCall(name: "noter", arguments: ["titre": "Lait"]))]
        let (model, speaker, tools) = (ScriptedModel(scripts: [two, [.text("Avec plaisir, à ton service.")]]),
                                       FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain et le lait", "Merci beaucoup"]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.joined().contains("redis-moi") }
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain"])
        #expect(await log.pieces.joined(separator: " ") == "C’est noté\(nb): Pain. " + ActionPhrases.oneThingAtATime(.french))
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user])
        #expect(history[2].toolCalls.first?.name == "noter")
        #expect(history[3].toolResult == ["id": "n1"])
    }

    @Test func fillerCoversTheTimeTheCallIsWritten() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note, [.text("Avec plaisir, à ton service.")]]),
                                       FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain", "Merci"]), speaker, tools, filler: true)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.joined().contains("Pain") }
        #expect(await log.pieces.joined(separator: " ") == ActionPhrases.oneMoment(.french) + " C’est noté\(nb): Pain.")
        // The model never sees the filler as its own words (it would start saying it everywhere).
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        #expect(history.filter { $0.role == .assistant }.map(\.content) == ["", "C’est noté\(nb): Pain."])
    }

    @Test func refusedCallGetsOneMoreTryThenAQuestion() async throws {
        let bad: [ModelOutput] = [.toolCall(ToolCall(name: "noter"))]
        let (model, speaker, tools) = (ScriptedModel(scripts: [bad, bad]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Note"]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { !(await log.pieces.isEmpty) }
        #expect(await model.requests.count == 2)
        let second = try #require(await model.requests.last)
        #expect(second.suffix(2).map(\.role) == [.assistant, .tool])  // the model sees why it was refused
        #expect(await log.pieces.joined(separator: " ") == ActionPhrases.missingTitle(.french))
        #expect(await tools.performed.isEmpty)
    }

    @Test func cancelIsHandledWithoutTheModel() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain", "Annule."]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.performed.count == 1 }
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.undone.count == 1 }
        #expect(await tools.undone == ["n1"])
        #expect(await model.requests.count == 1)  // "annule" never reached the model
    }

    @Test func timerAnnouncementWaitsForSilence() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "11111111")  // the user is speaking
        await pipeline.announce("Ton minuteur de 10 minutes est terminé.", note: "(Le minuteur a sonné.)",
                                language: .french)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.pieces.isEmpty)
        await push(pipeline, String(repeating: "0", count: 20))  // their turn ends, Maé answers…
        await waitFor { await log.pieces.contains("Ton minuteur de 10 minutes est terminé.") }  // …then the timer
        #expect(await log.pieces.last == "Ton minuteur de 10 minutes est terminé.")
    }
}
