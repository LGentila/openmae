// voice-cli dialogue-bench — the language model in short conversations, turn after turn, as the app has them.
//
// Text only, and nothing is carried out for real. Each dialogue of the corpus (Tests/Fixtures/dialogues-fr.json) is a
// few sentences of the user, sent one after the other at a fixed reference time, with the app's system prompt, tools and
// date line. Each turn goes as in the app (`VoicePipeline.runTurn`): "oui", "non" and "annule" are answered by the app;
// a call goes through the app's `ToolRunner`, whose checks refuse what the app would refuse, then ask the user at once
// (a date in the past, an hour that may be the morning or the afternoon) or give the model its second try (if that
// try says nothing, the app says its question); the actions are carried out on a calendar kept in memory
// (`MemoryCalendar`), which gives the model the results and the user the sentences the app would. The history keeps
// each turn as the app records it, and the next sentence follows, until the dialogue's goal is reached (the item the
// user wanted is saved, or changed) or its sentences run out; a dialogue whose last sentence asks for what is already
// so (an item put in the calendar it is in) has its goal checked at the end: nothing done, and nothing said done. The
// model samples its answers: each dialogue runs --repeats times (default 10), and the report counts, turn by turn, what
// the model did, which items its changes named (« dernier », "r1"), how many answers said nothing to the user, how many
// second tries answered in words that say it was done (« C'est noté », with nothing saved), how many answers with
// nothing done said something was noted, remembered or saved (« Je retiens que… ») and how often the goal was reached;
// and, for a dialogue that creates an item on the way that its later sentences must leave as it was, how often
// that item was changed or deleted.
//
//   voice-cli dialogue-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                            [--corpus Tests/Fixtures/dialogues-fr.json] [--repeats 10] [--agents] [--web]
//                            [--memory [--journal]]
//                            [--examples app|none|file] [--addendum file] [--watch-calls] [--out measurements]
//
// --agents (or "agents": true, as in Tests/Fixtures/agents-dialogues-fr.json) offers Claude Code's tools too, as in the
// app when it is on, with the app's read-back and the user's "oui", but an agent that does nothing: its tasks run until
// a sentence "[tâche terminée]" ends them, as finished, and the conversation gets the note the app gives it then
// (`AgentPhrases.historyNote`), with the user's next message. A dialogue whose goal is the delegation (deleguer_tache)
// reaches it in a turn after a task ended: the work handed over again (a call the app read back), or an answer that says
// the task is over (`answerMentions`); either way, never an answer that says it still runs (`answerNeverMentions`, which
// any goal may have). --web offers the web search too (nothing is searched: a call is declined). --memory (or
// "memory": true, as in Tests/Fixtures/memory-dialogues-fr.json) offers the memory's tool, with a sheet kept in memory,
// and its journal of past exchanges only as the app offers it on the tier (`MemorySettings.journalOffered(on:)`: the
// comfort tier) or with --journal: a dialogue may start with a sheet ("sheet"), a sentence "[nouvelle conversation]"
// starts a new conversation (the sheet read again), and its goal is checked once all its sentences are said (what the
// sheet holds, what the last answer says). --now replaces every reference time of the corpus (a dialogue may have its
// own). --examples and --addendum are those of actions-bench. --watch-calls adds each first pass's chance of opening a
// call (at its first token, and at its most tempted token).

import Foundation
import VoiceCore
import VoiceEngineApple

private struct DialogueCorpus: Decodable {
    var now: String
    /// Claude Code switched on: its tools are offered too (as with --agents).
    var agents: Bool?
    /// The web search switched on (as with --web).
    var web: Bool?
    /// The memory switched on (as with --memory).
    var memory: Bool?
    var dialogues: [Dialogue]

    struct Dialogue: Decodable {
        var name: String
        /// Another reference time for this dialogue (its goal's date follows it).
        var now: String?
        /// What the user says, in order; the next one only while the goal is not reached.
        var turns: [String]
        var goal: Goal
        /// An item the dialogue creates on the way, which the user never asks to change: its title contains `keep`
        /// (whatever the accents and case). The report counts the runs that changed or deleted it.
        var keep: String?
        /// The calendars and the reminder lists the app finds in this dialogue, the default one first (by default, one
        /// of each: « Maison » and « Rappels »).
        var calendars: [String]?
        var lists: [String]?
        /// The memory's sheet when the dialogue starts.
        var sheet: [String]?
    }

    /// The item the user wants saved: by this tool, its title containing `title` (whatever the accents and case), at
    /// `when` ("2026-10-16T16:00", or the day alone), in the calendar or the list `calendar` (whatever the accents and
    /// case). With `modifier_element`, an item created earlier in the dialogue that the user wants changed: the app
    /// changed it (it did not create it), its title, date and calendar as wanted. With `aucun` (`nothingToDo`), the last
    /// sentence asks for what is already so, checked once it is said: in its turn, no item changed or deleted, and an
    /// answer (the model's words and the app's sentences) that does not say anything was done, changed or moved. The
    /// report also counts the runs that created an item in that turn (the same one again, say).
    struct Goal: Decodable {
        var tool: String
        var title: String?
        var when: String?
        var calendar: String?
        /// The memory (`memoire`), checked once the dialogue's sentences are all said: at the end, the sheet holds an
        /// entry with this word (`remembered`), none (`forgotten`, `notRemembered`), or still one (`kept`); it is empty
        /// (`erased`); and the last answer mentions one of `answerMentions` (whatever the accents and case).
        var remembered: String?
        var forgotten: String?
        var kept: String?
        var notRemembered: String?
        var erased: Bool?
        var answerMentions: [String]?
        /// The turn that reaches the goal must not say any of these (whatever the accents and case): for the delegation,
        /// that the task still runs.
        var answerNeverMentions: [String]?

        /// The goal's tool for a last sentence that asks for nothing new.
        static let nothingToDo = "aucun"
    }
}

/// One pass of the model in a turn: the first, the second try after a refused call, or the summing up of a result.
private struct Pass: Encodable {
    var text: String
    /// The call it wrote, read as the app reads it (a misspelled name as the tool's, a memory action written as a
    /// tool's name as the memory's call).
    var call: ToolCall?
    var writtenName: String?
    /// What the app gave the model for it, and whether the app refused it.
    var result: JSONValue?
    var refused: Bool?
    /// The app created an item for this call (a change of the item whose creation was just refused creates it).
    var created: Bool?
    /// The app changed or deleted an item for this call: its title, as it was.
    var touched: String?
    var moreCalls: Bool?
    var unreadable: String?
    /// With --watch-calls: the pass exactly as the model wrote it, special tokens included (`MLXChatModel.lastRawAnswer`).
    var raw: String?
    /// With journal-bench's --watch-calls: the pass's tokens, each with its chance and the likeliest ones there
    /// (`MLXChatModel.lastTokens`).
    var tokens: [WatchedToken]?
}

private struct TurnResult: Encodable {
    var user: String
    /// "oui", "non" or "annule", answered by the app without the model.
    var answeredByApp: Bool?
    var passes: [Pass]
    /// The answer as the history keeps it: what the model said, then the app's sentences.
    var answer: String
    var goalReached: Bool
    var firstCallChance: Double?
    var bestCallChance: Double?
    /// The model's first answer wrote neither a word nor a call: it was asked once more (`VoicePipeline.answerWithTools`).
    var askedAgain: Bool?
    /// The model's words as the voice says them: `answer` without the app's sentences.
    var modelSaid: String?
    /// The model's sentences the app left out, as it does with the memory offered while nothing was saved in the turn:
    /// they said something was noted, remembered or saved (`SaveClaims`).
    var leftOut: [String]?
    /// Nothing done (no call, or every call refused), and the model's words, as the voice says them, say something was
    /// noted, remembered or saved (`SaveClaims`).
    var claimsASave: Bool?
}

private struct RunResult: Encodable {
    var dialogue: String
    var run: Int
    var turns: [TurnResult]
    /// The turn (from 1) at which the goal was reached.
    var goalAt: Int?
    /// The turn (from 1) at which the item to keep (`Dialogue.keep`) was first changed or deleted.
    var keptItemTouchedAt: Int?
    /// The tasks handed to the agent that "[tâche terminée]" ended.
    var tasksEnded: Int?
}

func runDialogueBench(_ o: Options) async throws {
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/dialogues-fr.json")
    let corpus = try JSONDecoder().decode(DialogueCorpus.self, from: Data(contentsOf: corpusURL))
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? corpus.now, in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }
    let tier = try tierOption(o)
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    guard o.llm != nil || store.isComplete([pack]) else {
        throw CLIError("\(pack.displayName) is not on this Mac: run “voice-cli download --tier \(tier.rawValue)” first")
    }
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue)) · reference time \(LocalDateTime.format(now, in: timeZone))")
    let model = try await MLXChatModel.load(directory: folder)

    // As the app with the actions on (no shortcut in the folder): its providers in its order, here with the calendar
    // in memory, and Claude Code or the web search as the model sees them (nothing handed over or searched).
    let agents = corpus.agents == true || o.agents
    let web = corpus.web == true || o.web
    let calendar = MemoryCalendar(movingItems: ActionCatalog.movesItems(on: tier))
    // The memory last, as in the app; off, it offers nothing.
    let memory = corpus.memory == true || o.memory
    let offered = MemorySettings.journalOffered(on: tier)
    let journal = offered || o.journal
    let memoryStore = TransientMemoryStore()
    let memoryTools = MemoryTools(store: memoryStore, enabled: memory, journal: journal, tier: tier)
    if memory {
        print("memory: on, " + (journal ? "with the journal" + (offered ? ", as the app on this tier" : " (--journal)")
            : "without the journal, as the app on this tier (--journal to offer it)"))
    }
    // Claude Code's tasks and their folders go into a folder of their own, removed at the end.
    let agentsFolder = FileManager.default.temporaryDirectory
        .appending(path: "openmae-dialogue-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: agentsFolder) }
    /// The app's tools, Claude Code's with an agent of their own: a fresh one for each run, with no task left from the
    /// run before.
    func makeRunner() async -> (ToolRunner, BenchAgents?) {
        let bench = agents ? await BenchAgents(folder: agentsFolder.appending(path: UUID().uuidString)) : nil
        let providers: [any ToolProvider] = [calendar, TimerTools()] + (bench.map { [$0.tools] } ?? [])
            + (web ? [DryWebSearch()] : []) + [memoryTools]
        let runner = ToolRunner(providers: providers)
        _ = await runner.tools()
        return (runner, bench)
    }
    var (runner, benchAgents) = await makeRunner()
    await model.useTools(await runner.tools())
    await model.watchToolCalls(o.watchCalls)
    let maxCalls = max(1, o.maxCalls ?? ActionCatalog.actionsPerRequest(on: tier))
    await model.limitToolCalls(maxCalls)
    print("calls carried out in one request: \(maxCalls) at most")
    var base = Conversation()
    let exampleCall = await model.toolCallText(ActionCatalog.example.call)
    base.systemAddenda = [try o.addendum.map { try String(contentsOfFile: $0, encoding: .utf8) }
        ?? ActionCatalog.promptAddendum(exampleCall: exampleCall)] + (await runner.promptAddenda())
    let examples = o.examples ?? (ActionCatalog.showsExamples(on: tier) ? "app" : "none")
    base.examples = try exampleExchanges(examples, now: now, timeZone: timeZone)
    print("example exchanges: \(examples) (\(base.examples.filter { $0.role == .user }.count))")
    try await model.prefillBeginning(base.beginning)
    let toolCount = await runner.tools().count
    let promptTokens = try await model.tokenCount(base.messages)
    print("system prompt with \(toolCount) tools: \(promptTokens) tokens\n")

    let repeats = max(o.repeats ?? 10, 1)
    var runs: [RunResult] = []
    for dialogue in corpus.dialogues {
        var at = now
        if o.now == nil, let own = dialogue.now {
            guard let date = LocalDateTime.parse(own, in: timeZone)?.date else {
                throw CLIError("\(dialogue.name): expected a date like 2026-10-15T18:42")
            }
            at = date
        }
        await calendar.use(calendars: dialogue.calendars, lists: dialogue.lists)
        let memoryGoal = dialogue.goal.tool == MemoryCatalog.name
        let nothingToDo = dialogue.goal.tool == DialogueCorpus.Goal.nothingToDo
        let delegationGoal = dialogue.goal.tool == AgentCatalog.delegateName
        let endsTasks = dialogue.turns.contains(taskEndedMarker)
        for run in 1...repeats {
            print("■ \(dialogue.name) — run \(run)/\(repeats)" + (at == now ? "" : " · at \(LocalDateTime.format(at, in: timeZone))"))
            if agents { (runner, benchAgents) = await makeRunner() }
            var start = base
            if memory {
                // The dialogue's sheet, read as at a new conversation (the beginning changes with it).
                try await memoryStore.saveSheet(dialogue.sheet ?? [])
                await runner.resetConversation()
                start.systemAddenda = Array(base.systemAddenda.dropLast()) + [await memoryTools.promptAddendum() ?? ""]
                try await model.prefillBeginning(start.beginning)
            }
            var talk = Talk(model: model, runner: runner, calendar: calendar, conversation: start, now: at,
                            timeZone: timeZone, watchCalls: o.watchCalls, maxCalls: maxCalls)
            var result = RunResult(dialogue: dialogue.name, run: run, turns: [])
            for (index, sentence) in dialogue.turns.enumerated() {
                if sentence == "[nouvelle conversation]" {
                    // As "Nouvelle conversation" in the app: the sheet read again, the beginning computed again if it
                    // changed, the history gone.
                    await runner.resetConversation()
                    if memory {
                        start.systemAddenda = Array(base.systemAddenda.dropLast())
                            + [await memoryTools.promptAddendum() ?? ""]
                    }
                    try await model.prefillBeginning(start.beginning)
                    talk.conversation = start
                    print("  — new conversation")
                    continue
                }
                if sentence == taskEndedMarker {
                    // As in the app when the agent is done: the task ends on its own, a notification tells the user, and
                    // the conversation gets its note with the user's next message.
                    let ended = await benchAgents?.endTasks() ?? []
                    for task in ended { talk.conversation.noteForNextMessage(AgentPhrases.historyNote(for: task)) }
                    result.tasksEnded = (result.tasksEnded ?? 0) + ended.count
                    print("  — " + (ended.isEmpty ? "no task was running"
                        : ended.map { "\($0.reference) « \($0.title) » ended" }.joined(separator: ", ")))
                    continue
                }
                var turn = try await talk.turn(sentence)
                if claimsASave(turn) { turn.claimsASave = true }
                if memoryGoal || nothingToDo || (endsTasks && (result.tasksEnded ?? 0) == 0) {
                    // A dialogue about a task that ended reaches nothing before one did.
                    turn.goalReached = false
                } else if delegationGoal {
                    turn.goalReached = handsOverOrSaysOver(turn, dialogue.goal)
                } else {
                    turn.goalReached = turn.passes.contains { reaches($0, dialogue.goal) }
                }
                let said = turn.goalReached ? mentioned(dialogue.goal.answerNeverMentions, in: turn.answer) : nil
                if said != nil { turn.goalReached = false }
                result.turns.append(turn)
                show(turn, index: index + 1)
                if let said { print("  ✗ the answer says « \(said) »") }
                if let keep = dialogue.keep, result.keptItemTouchedAt == nil,
                   turn.passes.contains(where: { $0.touched.map { folded($0).contains(folded(keep)) } ?? false })
                {
                    result.keptItemTouchedAt = index + 1
                }
                if turn.goalReached {
                    result.goalAt = index + 1
                    break
                }
            }
            if memoryGoal, let last = result.turns.last {
                let sheet = MemoryText.folded(try await memoryStore.sheet().joined(separator: " | "))
                let goal = dialogue.goal
                var reached = true
                if let word = goal.remembered { reached = reached && sheet.contains(MemoryText.folded(word)) }
                if let word = goal.kept { reached = reached && sheet.contains(MemoryText.folded(word)) }
                if let word = goal.forgotten { reached = reached && !sheet.contains(MemoryText.folded(word)) }
                if let word = goal.notRemembered { reached = reached && !sheet.contains(MemoryText.folded(word)) }
                if goal.erased == true { reached = reached && sheet.isEmpty }
                if let words = goal.answerMentions {
                    let answer = MemoryText.folded(last.answer)
                    reached = reached && words.contains { answer.contains(MemoryText.folded($0)) }
                }
                print("  sheet at the end: \(try await memoryStore.sheet())")
                if reached {
                    result.goalAt = result.turns.count
                    result.turns[result.turns.count - 1].goalReached = true
                }
            }
            if nothingToDo, let last = result.turns.last {
                // The last sentence asked for what was already so.
                let touched = last.passes.contains { $0.touched != nil }
                let claimed = saysItWasDone(last.answer)
                if !touched, !claimed {
                    result.goalAt = result.turns.count
                    result.turns[result.turns.count - 1].goalReached = true
                } else {
                    print("  ✗ at the last turn: " + [touched ? "an item changed or deleted" : nil,
                                                      claimed ? "the answer says it was done" : nil]
                        .compactMap { $0 }.joined(separator: ", "))
                }
                if last.passes.contains(where: { $0.created == true }) { print("  ✗ an item created at the last turn") }
            }
            if let keep = dialogue.keep, let touchedAt = result.keptItemTouchedAt {
                print("  ✗ « \(keep) » changed or deleted at turn \(touchedAt)")
            }
            print(result.goalAt.map { "  ✓ goal reached at turn \($0)\n" } ?? "  ✗ goal not reached\n")
            runs.append(result)
            // As "Nouvelle conversation" in the app: nothing created is kept, the model goes back to the beginning.
            await runner.resetConversation()
            try await model.prefillBeginning(base.beginning)
        }
    }
    summarize(runs, corpus: corpus)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("dialogue-bench-\(tier.rawValue)-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(runs).write(to: url)
    print("report: \(url.path)")
}

/// A conversation, turn after turn, as `VoicePipeline.runTurn` has it (without the voice).
private struct Talk {
    let model: MLXChatModel
    let runner: ToolRunner
    let calendar: MemoryCalendar
    var conversation: Conversation
    let now: Date
    let timeZone: TimeZone
    let watchCalls: Bool
    /// The calls the app carries out in one request (`PipelineConfig.actionsPerRequest`).
    let maxCalls: Int

    init(model: MLXChatModel, runner: ToolRunner, calendar: MemoryCalendar, conversation: Conversation, now: Date,
         timeZone: TimeZone, watchCalls: Bool, maxCalls: Int)
    {
        self.model = model
        self.runner = runner
        self.calendar = calendar
        self.conversation = conversation
        self.now = now
        self.timeZone = timeZone
        self.watchCalls = watchCalls
        self.maxCalls = maxCalls
    }

    mutating func turn(_ text: String) async throws -> TurnResult {
        // With what happened meanwhile (a task that ended), as the app makes it.
        let message = conversation.nextUserMessage(text, language: .french,
                                                   dateLine: ActionCatalog.dateLine(now, timeZone: timeZone))
        // As the app: what the user said, this turn then the two before (their messages without the date line).
        let earlier = conversation.exchanges.filter { $0.role == .user }.suffix(2).reversed()
            .map { $0.content.components(separatedBy: "\n").first ?? "" }
        let context = ToolContext(now: now, timeZone: timeZone, language: .french, userSaid: [text] + earlier)
        var result = TurnResult(user: text, passes: [], answer: "", goalReached: false)
        var answer = ""
        var steps: [ChatMessage] = []
        /// What `steps` already hold of the answer (`Conversation.summingUpSteps`).
        var answerInSteps = ""
        /// The app's own sentences, one at a time (`VoicePipeline.say`).
        func say(_ sentence: String) {
            var chunker = SentenceChunker()
            chunker.firstPieceMinCharacters = .max
            (chunker.push(sentence) + chunker.flush()).forEach { SpeakableText.record($0, in: &answer) }
        }
        if let interception = await runner.interception(for: text, now: now),
           let reply = await runner.resolve(interception, context: context)
        {
            result.answeredByApp = true
            say(reply.spoken)
        } else {
            var request = conversation.messages(adding: message)
            var filter = ReasoningFilter()
            var chunker = SentenceChunker()
            var modelSaid = ""
            func send(_ piece: SentenceChunker.Piece) {
                SpeakableText.record(piece.text, after: piece.separator, in: &answer)
                SpeakableText.record(piece.text, after: piece.separator, in: &modelSaid)
            }
            // As the app: with the memory offered, the model's sentences that say something was saved are left out
            // while nothing was, except in a summing up (`VoicePipeline.answerWithTools`).
            var unsaved = await runner.offers(MemoryCatalog.name)
            // As the app (`VoicePipeline.answerWithTools`): the calls carried out in order, at most `maxCalls`; one second
            // try for the refused ones, only they (or calls standing for them) carried out from it, none twice, opening with
            // a call when the refusals want one; one summing up of what came from outside,
            // no call carried out then; the app's questions, the one for the sensitive calls, and how many things it does
            // at a time when the model asked for more; a first answer with neither a word nor a call asked for once more.
            enum Kind { case first, secondTry, summing }
            var kind = Kind.first
            var askedForMore = false
            var askedAgain = false
            var begun = false
            var carriedOut: [ToolCall] = []
            var toCorrect: [(tools: Set<String>, question: String)] = []
            var secondTryOpening = AnswerOpening.free
            var questions: [String] = []
            var waitsForYes = false
            var toSum: [String] = []
            var summedUpAgain = false
            var several = false
            /// How long the answer was right after the last action's confirmation: the next one may be linked to it.
            var confirmationEnd: Int?
            let alone = ToolContext(now: now, timeZone: timeZone, language: .french)
            while true {
                var calls: [ToolCall] = []
                var results: [JSONValue] = []
                var refusedHere: [(index: Int, question: String, refusal: ToolRefusal)] = []
                var ignored: [ToolCall] = []
                var pass = Pass(text: "")
                var passes: [Pass] = []
                // The whole pass first: whether another call follows a call tells whether the user asked for several
                // actions (the app knows it at the model's next output, before carrying the call out).
                var outputs: [ModelOutput] = []
                let opening = kind == .secondTry ? secondTryOpening : .free
                let leavesOutClaims = unsaved && kind != .summing
                chunker.leavesOutSaveClaims = leavesOutClaims
                for try await output in model.reply(to: request, opening: opening) { outputs.append(output) }
                for (place, output) in outputs.enumerated() {
                    let followed = outputs[(place + 1)...].first.map { if case .text = $0 { false } else { true } } ?? false
                    switch output {
                    case .text(let raw):
                        pass.text += raw
                        chunker.pieces(adding: filter.push(raw)).forEach(send)
                    case .toolCall(let written) where kind != .summing:
                        guard calls.count < maxCalls else {
                            askedForMore = true
                            break
                        }
                        if kind == .first, followed || !calls.isEmpty { several = true }
                        chunker.remainingPieces().forEach(send)
                        let call = await runner.named(written)
                        calls.append(call)
                        var callPass = Pass(text: "", call: call, writtenName: written.name == call.name ? nil : written.name)
                        if kind == .secondTry {
                            if carriedOut.contains(call) {
                                results.append(["statut": .string(ToolOutcome.alreadyDone)])
                                callPass.result = results.last
                                passes.append(callPass)
                                continue
                            }
                            guard let index = toCorrect.firstIndex(where: { $0.tools.contains(call.name) }) else {
                                results.append(["erreur": .string(ToolOutcome.onlyRefusedCalls)])
                                callPass.result = results.last
                                passes.append(callPass)
                                continue
                            }
                            toCorrect.remove(at: index)
                        }
                        let creationsBefore = await calendar.creations.count
                        let touchedBefore = await calendar.touched.count
                        // As the app: for one of several actions, only the call's own words.
                        let reply = await runner.handle(call, context: several ? alone : context, sameRequest: begun)
                        begun = true
                        if await calendar.creations.count > creationsBefore { callPass.created = true }
                        let touched = await calendar.touched
                        if touched.count > touchedBefore { callPass.touched = touched.last }
                        results.append(reply.forModel)
                        callPass.result = reply.forModel
                        if case .object(let fields) = reply.forModel, fields["erreur"] != nil { callPass.refused = true }
                        if let refusal = reply.refusal {
                            if reply.retryable, kind == .first {
                                refusedHere.append((calls.count - 1, reply.spoken, refusal))
                            } else {
                                questions.append(reply.spoken)
                            }
                        } else if reply.waitsForYes {
                            waitsForYes = true
                        } else {
                            carriedOut.append(call)
                            if call.name == MemoryCatalog.name, MemoryCatalog.action(call) == .retenir {
                                unsaved = false
                                chunker.leavesOutSaveClaims = false
                            }
                            if reply.modelSpeaks {
                                toSum.append(reply.spoken)
                            } else {
                                // As the app (`VoicePipeline.confirm`): the last of several confirmations said one
                                // after the other is linked to the one before.
                                let more = followed && calls.count < maxCalls && (kind == .first || !toCorrect.isEmpty)
                                let last = !more && !(kind == .first && !refusedHere.isEmpty && toSum.isEmpty)
                                let link = last && confirmationEnd == answer.count && reply.confirms
                                say(link ? ActionPhrases.linked(reply.spoken, .french) : reply.spoken)
                                confirmationEnd = reply.confirms ? answer.count : nil
                            }
                        }
                        passes.append(callPass)
                    case .moreToolCalls where kind != .summing:
                        askedForMore = true
                        if kind == .first { several = true }
                    case .unreadableToolCall(let raw) where kind != .summing: pass.unreadable = raw
                    case .toolCall(let call): ignored.append(call)
                    default: break
                    }
                }
                chunker.pieces(adding: filter.flush()).forEach(send)
                var cleaned = ReasoningFilter()
                pass.text = (cleaned.push(pass.text) + cleaned.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
                let modelWrote = !SpeakableText.clean(pass.text).isEmpty
                let modelSpoke = modelWrote
                    && (!leavesOutClaims || !SpeakableText.clean(SaveClaims.spoken(pass.text).said).isEmpty)
                if result.passes.isEmpty, watchCalls, let chances = await model.lastToolCallChances {
                    result.firstCallChance = chances.first
                    result.bestCallChance = chances.best
                }
                if watchCalls {
                    pass.raw = await model.lastRawAnswer
                    let tokens = await model.lastTokens  // empty unless the model watches its tokens
                    pass.tokens = tokens.isEmpty ? nil : tokens
                }
                if askedForMore { pass.moreCalls = true }
                // The pass's text on its first call (or alone), each call after it.
                if var first = passes.first {
                    first.text = pass.text
                    first.moreCalls = pass.moreCalls
                    first.unreadable = pass.unreadable
                    first.raw = pass.raw
                    first.tokens = pass.tokens
                    passes[0] = first
                    result.passes += passes
                } else {
                    result.passes.append(pass)
                }
                if kind == .summing {
                    chunker.remainingPieces().forEach(send)
                    if !modelSpoke, !ignored.isEmpty, !summedUpAgain {
                        summedUpAgain = true
                        steps += [.calls(ignored)]
                            + ignored.map { .result(of: $0, ["erreur": .string(ToolOutcome.noCallWhileSummingUp)]) }
                        request = conversation.messages(adding: message) + steps
                        continue
                    }
                    if !modelSpoke { for fallback in toSum.uniquedStrings() { say(fallback) } }
                    break
                }
                let secondTry = !refusedHere.isEmpty && toSum.isEmpty
                if !secondTry {
                    for refusal in refusedHere {
                        results[refusal.index] = ["erreur": .string(refusal.refusal.forModel)]
                        questions.append(refusal.question)
                    }
                }
                if !calls.isEmpty { steps += [.calls(calls)] + zip(calls, results).map { .result(of: $0, $1) } }
                if kind == .secondTry {
                    chunker.remainingPieces().forEach(send)
                    if !modelSpoke, !toCorrect.isEmpty { questions = toCorrect.map(\.question) + questions }
                    toCorrect = []
                }
                if calls.isEmpty, pass.unreadable != nil {
                    chunker.remainingPieces().forEach(send)
                    say(ActionPhrases.notUnderstood(.french))
                    break
                }
                if kind == .first, calls.isEmpty, !askedForMore, !modelWrote {
                    if !askedAgain {
                        askedAgain = true
                        result.askedAgain = true
                        continue
                    }
                    chunker.remainingPieces().forEach(send)
                    say(ActionPhrases.notUnderstood(.french))
                    break
                }
                if secondTry {
                    toCorrect = refusedHere.map { ($0.refusal.correctedBy.union([calls[$0.index].name]), $0.question) }
                    secondTryOpening = refusedHere.allSatisfy(\.refusal.secondTryIsACall) ? .toolCall : .free
                    kind = .secondTry
                    request = conversation.messages(adding: message) + steps
                    continue
                }
                if !toSum.isEmpty, !calls.isEmpty {
                    kind = .summing
                    // As the app: what was said so far ends the answer, and the app's note asks for the rest.
                    if !answer.isEmpty {
                        steps += Conversation.summingUpSteps(after: answer)
                        answerInSteps = answer
                    }
                    request = conversation.messages(adding: message) + steps
                    continue
                }
                break
            }
            let last = chunker.remainingPieces()
            last.forEach { SpeakableText.record($0.text, after: $0.separator, in: &modelSaid) }
            // As the app: an answer left with nothing to say, or too little for the voice, once its claims are out.
            let ending = !chunker.leftOutClaims.isEmpty && answer.isEmpty && questions.isEmpty && !waitsForYes
                && !askedForMore ? SaveClaims.ending(last, language: .french) : last
            ending.forEach { SpeakableText.record($0.text, after: $0.separator, in: &answer) }
            for question in questions.uniquedStrings() { say(question) }
            if waitsForYes, let question = await runner.pendingQuestion(.french) { say(question) }
            if askedForMore { say(ActionPhrases.atMost(maxCalls, .french)) }
            if !chunker.leftOutClaims.isEmpty { result.leftOut = chunker.leftOutClaims }
            result.modelSaid = modelSaid
        }
        result.answer = answer
        // As the app (`VoicePipeline.Turn.answerAfterSteps`): the steps already hold what was said before the summing up.
        let recorded = answerInSteps.isEmpty || !answer.hasPrefix(answerInSteps) ? answer
            : String(answer.dropFirst(answerInSteps.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.record(user: message, steps: steps, assistant: recorded, interrupted: false)
        await model.catchUp(with: conversation.messages)
        return result
    }
}

/// The sentence of a dialogue that ends the tasks handed to the agent (`BenchAgents.endTasks`).
private let taskEndedMarker = "[tâche terminée]"

/// Claude Code switched on, as in the app: the app's own tools (`AgentTools`), with its part of the prompt, its read-back
/// and the user's "oui" (the default setting), but an agent that does nothing (`BenchAgent`): its tasks run until
/// `endTasks`.
private struct BenchAgents {
    let tools: AgentTools
    private let agent = BenchAgent()
    private let ended = EndedTasks()

    init(folder: URL) async {
        tools = AgentTools(store: TaskStore(folder: folder.appending(path: "Tasks", directoryHint: .isDirectory)),
                           workspace: folder.appending(path: "OpenMae", directoryHint: .isDirectory))
        let ended = ended
        await tools.observe(onChange: { _ in }, onEnd: { task in Task { await ended.add(task) } })
        await tools.configure(agents: [AgentTools.Agent(connector: agent)], folders: [])
    }

    /// Ends the tasks that run, as finished; returns them once the app's tools have told their end (`onEnd`, which shows
    /// the notification in the app), within five seconds.
    func endTasks() async -> [AgentTask] {
        let count = agent.finishAll()
        for _ in 0..<500 where await ended.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        return await ended.take()
    }
}

/// The tasks whose end the app's tools told.
private actor EndedTasks {
    private var tasks: [AgentTask] = []
    var count: Int { tasks.count }
    func add(_ task: AgentTask) { tasks.append(task) }
    func take() -> [AgentTask] {
        defer { tasks = [] }
        return tasks
    }
}

/// An agent that does nothing: each run waits for `finishAll`, then ends with a short result, as Claude Code's does.
private final class BenchAgent: AgentConnector, @unchecked Sendable {
    let agentID = ClaudeCode.agentID
    let displayName = ClaudeCode.displayName
    private let lock = NSLock()
    private var runs: [UUID: AsyncThrowingStream<AgentUpdate, Error>.Continuation] = [:]

    func availability() async -> AgentAvailability { .ready(version: nil) }

    func start(_ task: AgentTask) -> AsyncThrowingStream<AgentUpdate, Error> {
        let (stream, run) = AsyncThrowingStream<AgentUpdate, Error>.makeStream()
        run.yield(.session(task.id.uuidString))
        lock.withLock { runs[task.id] = run }
        return stream
    }

    func followUp(_ task: AgentTask, message: String) -> AsyncThrowingStream<AgentUpdate, Error> { start(task) }

    /// Ends every run, as finished; returns how many there were.
    func finishAll() -> Int {
        let ending = lock.withLock {
            defer { runs = [:] }
            return Array(runs.values)
        }
        for run in ending {
            run.yield(.result(AgentResult(text: "Le travail demandé est fait : tout est dans le dossier de la tâche.")))
            run.finish()
        }
        return ending.count
    }

    /// As Claude Code: a run stopped still ends with a result, an error.
    func cancel(_ task: AgentTask) async {
        let run = lock.withLock { runs.removeValue(forKey: task.id) }
        run?.yield(.result(AgentResult(text: "", failure: .agent("error_during_execution"))))
        run?.finish()
    }
}

/// The web search switched on, as the model sees it. No search is made: a call is declined.
private struct DryWebSearch: ToolProvider {
    let identifier = "web-search"
    func tools() async -> [ToolSpec] { [WebSearchCatalog.search] }
    func promptAddendum() async -> String? { WebSearchCatalog.promptAddendum }
    func risk(of call: ToolCall) async -> ToolRisk { .read }
    func check(_ call: ToolCall, context: ToolContext) async throws { try WebSearchCatalog.check(call, context: context) }
    func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        throw ToolRefusal(forModel: "Recherche non effectuée (essai).", spoken: ActionPhrases.declined(context.language),
                          retryable: false)
    }
}

/// Whether a pass saved the goal's item: an item of the goal's tool's kind (an event for creer_evenement, a reminder for
/// creer_rappel) that the app created, its title, date and calendar or list as wanted. Whatever call the model wrote: a
/// change of the item whose creation was just refused creates it. For modifier_element: an item that the app changed,
/// not created, whatever call the model wrote but a deletion: a creation of an item already there, written again in
/// another calendar or list the user names, moves it (`ActionCatalog.moved`).
private func reaches(_ pass: Pass, _ goal: DialogueCorpus.Goal) -> Bool {
    let change = goal.tool == ActionCatalog.changeItem.name
    let saved = change ? pass.call?.name != ActionCatalog.deleteItem.name && pass.touched != nil && pass.created != true
        : pass.created == true
    guard saved, pass.refused != true, case .object(let fields)? = pass.result, fields["id"] != nil,
          change || (fields["liste"] != nil) == (goal.tool == ActionCatalog.createReminder.name)
    else { return false }
    if let title = goal.title {
        guard let saved = fields["titre"]?.text, folded(saved).contains(folded(title)) else { return false }
    }
    if let when = goal.when {
        guard let saved = (fields["debut"] ?? fields["echeance"])?.text else { return false }
        // To the minute, or the day alone.
        guard when.contains("T") ? saved == when : saved.hasPrefix(when) else { return false }
    }
    if let calendar = goal.calendar {
        guard let saved = (fields["calendrier"] ?? fields["liste"])?.text, folded(saved) == folded(calendar) else {
            return false
        }
    }
    return true
}

private func folded(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
}

/// Whether a turn after a task ended reached the delegation's goal: the work handed over again (a deleguer_tache call the
/// app did not refuse: read back, waiting for the "oui"), or an answer that says the task is over (one of
/// `answerMentions`). What it must not say (`answerNeverMentions`: that the task still runs) is checked apart.
private func handsOverOrSaysOver(_ turn: TurnResult, _ goal: DialogueCorpus.Goal) -> Bool {
    turn.passes.contains { $0.call?.name == AgentCatalog.delegateName && $0.refused != true }
        || mentioned(goal.answerMentions, in: turn.answer) != nil
}

/// The first of `words` that the answer says, whatever the accents, the case and the apostrophes; nil if none.
private func mentioned(_ words: [String]?, in answer: String) -> String? {
    func plain(_ text: String) -> String { folded(text).replacingOccurrences(of: "’", with: "'") }
    let text = plain(answer)
    return words?.first { text.contains(plain($0)) }
}

/// The sentences of a dialogue that are not the user's: a new conversation, the end of the agent's tasks.
private func isMarker(_ sentence: String) -> Bool {
    sentence == "[nouvelle conversation]" || sentence == taskEndedMarker
}

/// Whether words say an item was saved, changed, moved or erased, or is being: « C'est noté », « C'est fait », « C'est
/// déplacé », « J'ai ajouté… », « Je l'ai mis… », « Je la mets… » (not « Tu veux que je la décale ? »), « … est
/// enregistré », « … est maintenant dans… », « J'ai effacé l'information sur ton chien. ». Said in a pass without a
/// call, nothing was.
private func saysItWasDone(_ text: String) -> Bool {
    let done = "(ajouté|créé|utilisé|mis|enregistré|noté|programmé|placé|calé|planifié|réservé|inscrit|déplacé|décalé"
        + "|modifié|changé|effacé|supprimé|oublié|retiré)"
    let saved = "(noté|fait|enregistré|ajouté|programmé|créé|planifié|réservé|calé|mis|inscrit|déplacé|décalé|modifié"
        + "|changé|effacé|supprimé|oublié|retiré)"
    let doing = "(mets|ajoute|note|enregistre|programme|place|inscris|déplace|décale|modifie|change)"
    let patterns = [#"\bc'est (bien |donc )?"# + saved + #"\b"#, #"\bj'ai (bien |donc )?"# + done,
                    #"\bje (te |t')?l'ai (bien |donc )?"# + done, #"\btu as (bien )?noté\b"#,
                    #"\b(est|sont) (bien |maintenant |désormais )?"# + saved, #"\b(est|sont) (maintenant|désormais)\b"#,
                    #"(?<!que )\bje (te |t')?(le |la |les |l')?"# + doing + #"\b"#]
    let text = text.replacingOccurrences(of: "’", with: "'")
    return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
}

/// Whether the model answered a turn with nothing done (no call carried out, or waiting for the user's "oui": none, or
/// all refused) in words that, as the voice says them, say something was noted, remembered or saved (`SaveClaims`).
/// `written`: in its words as it wrote them, before the app left such sentences out.
private func claimsASave(_ turn: TurnResult, written: Bool = false) -> Bool {
    guard turn.answeredByApp != true, !turn.passes.contains(where: { $0.call != nil && $0.refused != true }) else {
        return false
    }
    return SaveClaims.saysItWasSaved(written ? turn.passes.map(\.text).joined(separator: " ") : turn.modelSaid ?? "")
}

private func show(_ turn: TurnResult, index: Int) {
    let chance = turn.bestCallChance.map {
        String(format: "  (call chance %.0f %% first, %.0f %% at most)", (turn.firstCallChance ?? 0) * 100, $0 * 100)
    } ?? ""
    print("  \(index) 🗣 \(turn.user)" + chance)
    if turn.answeredByApp == true { print("      (answered by the app)") }
    for (number, pass) in turn.passes.enumerated() {
        let label = number == 0 ? "→" : "then →"
        if let call = pass.call {
            let deleted = call.name == ActionCatalog.deleteItem.name
            let made = pass.created == true ? "created "
                : pass.touched.map { (deleted ? "deleted" : "changed") + " « \($0) »: " } ?? ""
            let verdict = pass.refused == true ? "  [refused: \(pass.result?.objectText("erreur") ?? "")]"
                : pass.result.map { "  = " + made + describe($0) } ?? ""
            print("      \(label) \((pass.writtenName.map { "\($0) → " } ?? "") + describe(call))" + verdict
                  + (pass.moreCalls == true ? "  [then another call, not carried out]" : ""))
            if !pass.text.isEmpty { print("        (before the call: “\(pass.text)”)") }
        } else if let raw = pass.unreadable {
            print("      \(label) unreadable call: \(raw)")
        } else {
            print("      \(label) no call: “\(pass.text)”")
        }
    }
    print("      🔊 \(turn.answer)")
    if let leftOut = turn.leftOut {
        print("      (left out, nothing was saved: " + leftOut.map { "« \($0) »" }.joined(separator: " ") + ")")
    }
    if turn.claimsASave == true { print("      ✗ says something was saved: nothing was") }
}

private func describe(_ call: ToolCall) -> String {
    "\(call.name) {" + call.arguments.sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value.text ?? "\($0.value)")" }.joined(separator: ", ") + "}"
}

private func describe(_ value: JSONValue) -> String {
    guard case .object(let fields) = value else { return "\(value)" }
    return "{" + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text ?? "\($0.value)")" }
        .joined(separator: ", ") + "}"
}

extension JSONValue {
    fileprivate func objectText(_ key: String) -> String? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]?.text
    }
}

/// Per dialogue: how often the goal was reached and at which turn, and how often the item to keep was changed or
/// deleted; per turn, what the model did at its first pass and at its second try ("nothing said": no call and not a
/// word), over the runs that got that far, which items its changes and deletions named, how many second tries after a
/// refused call answered in words that say it was done, how many answers with nothing done said something was saved,
/// and how many answers left the user in silence. Then, over every dialogue, the answers with nothing done that said
/// something was noted, remembered or saved.
private func summarize(_ runs: [RunResult], corpus: DialogueCorpus) {
    func outcome(_ pass: Pass) -> String {
        guard let call = pass.call else {
            if pass.unreadable != nil { return "unreadable call" }
            return SpeakableText.clean(pass.text).isEmpty ? "nothing said" : "no call"
        }
        let creation = [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name].contains(call.name)
        if creation, pass.refused != true, pass.touched != nil { return call.name + " (moved)" }
        // The memory's action too: « memoire/effacer_memoire ».
        let action = call.name == MemoryCatalog.name ? "/" + (MemoryCatalog.action(call)?.rawValue ?? "?") : ""
        return call.name + action
            + (pass.refused == true ? " (refused)" : pass.created == true && !creation ? " (created)" : "")
    }
    /// "creer_evenement (refused) 9, no call 1": the most frequent first.
    func counts(_ outcomes: [String]) -> String {
        var tally: [String: Int] = [:]
        for outcome in outcomes { tally[outcome, default: 0] += 1 }
        let sorted: [(String, Int)] = tally.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .map { ($0.key, $0.value) }
        return sorted.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
    /// "at turn 2: 9, at turn 3: 1".
    func byTurn(_ turns: [Int]) -> String {
        var atTurn: [Int: Int] = [:]
        for turn in turns { atTurn[turn, default: 0] += 1 }
        return atTurn.keys.sorted().map { "at turn \($0): \(atTurn[$0] ?? 0)" }.joined(separator: ", ")
    }
    for dialogue in corpus.dialogues {
        let mine = runs.filter { $0.dialogue == dialogue.name }
        let reached = mine.compactMap(\.goalAt)
        print("\n=== \(dialogue.name) — \(mine.count) runs ===")
        print("goal reached: \(reached.count) / \(mine.count)" + (reached.isEmpty ? "" : " (\(byTurn(reached)))"))
        if let keep = dialogue.keep {
            let touched = mine.compactMap(\.keptItemTouchedAt)
            print("« \(keep) » changed or deleted: \(touched.count) / \(mine.count)"
                  + (touched.isEmpty ? "" : " (\(byTurn(touched)))"))
        }
        if dialogue.goal.tool == DialogueCorpus.Goal.nothingToDo {
            // What the last turn did, when it should have done nothing.
            let last = mine.compactMap(\.turns.last)
            print("at the last turn: answers that say it was done \(last.filter { saysItWasDone($0.answer) }.count), "
                  + "items changed or deleted \(last.filter { $0.passes.contains { $0.touched != nil } }.count), "
                  + "items created \(last.filter { $0.passes.contains { $0.created == true } }.count) / \(last.count)")
        }
        // The runs' turns are the user's sentences only: the markers ("[nouvelle conversation]", "[tâche terminée]")
        // are counted in the turns' numbers, as in the runs' lines, but have no turn of their own.
        var said = -1
        for (index, sentence) in dialogue.turns.enumerated() where !isMarker(sentence) {
            said += 1
            let turns = mine.compactMap { $0.turns.count > said ? $0.turns[said] : nil }
            guard !turns.isEmpty else { continue }
            print("turn \(index + 1) “\(sentence)” (\(turns.count) runs)")
            if let words = dialogue.goal.answerNeverMentions, dialogue.turns[..<index].contains(taskEndedMarker) {
                let saying = turns.filter { mentioned(words, in: $0.answer) != nil }.count
                print("  answers that say one of « \(words.joined(separator: " », « ")) »: \(saying) / \(turns.count)")
            }
            print("  first pass: " + counts(turns.map { $0.passes.first.map(outcome) ?? "answered by the app" }))
            let second = turns.compactMap { $0.passes.count > 1 ? $0.passes[1] : nil }
            if !second.isEmpty { print("  second pass: " + counts(second.map(outcome))) }
            // The items the changes and deletions named, at any pass: « dernier », or an id, shown by its letter ("r…":
            // the ids go on from one run to the next, as from one conversation to the next in the app).
            let named = turns.flatMap(\.passes).compactMap { pass -> String? in
                guard let call = pass.call,
                      [ActionCatalog.changeItem.name, ActionCatalog.deleteItem.name].contains(call.name)
                else { return nil }
                var reference = call.text("reference") ?? "none"
                if reference.range(of: #"^[a-z]\d+$"#, options: .regularExpression) != nil {
                    reference = String(reference.prefix(1)) + "…"
                }
                return reference + (call.name == ActionCatalog.deleteItem.name ? " (deletion)" : "")
            }
            if !named.isEmpty { print("  items named by changes: " + counts(named)) }
            // The second tries after a refused call that answered in words: how many say it was done.
            let worded = turns.filter { $0.passes.first?.refused == true && $0.passes.count > 1 }.map { $0.passes[1] }
                .filter { outcome($0) == "no call" }
            let claiming = worded.filter { saysItWasDone($0.text) }.count
            if !worded.isEmpty { print("  second tries in words that say it was done: \(claiming) / \(worded.count)") }
            let claims = turns.filter { $0.claimsASave == true }.count
            if claims > 0 { print("  answers with nothing done that say something was saved: \(claims) / \(turns.count)") }
            let written = turns.filter { claimsASave($0, written: true) }.count
            if written > 0 {
                print("  answers with nothing done written so by the model, before the app left those sentences out: "
                      + "\(written) / \(turns.count)")
            }
            let silent = turns.filter { $0.answer.isEmpty }.count
            if silent > 0 { print("  silent answers (nothing said to the user): \(silent)") }
            let chances = turns.compactMap(\.firstCallChance)
            if !chances.isEmpty {
                print(String(format: "  call chance at the first token: median %.0f %% (%.0f–%.0f %%)",
                             (median(chances) ?? 0) * 100, (chances.min() ?? 0) * 100, (chances.max() ?? 0) * 100))
            }
        }
    }
    let byModel = runs.flatMap(\.turns).filter { $0.answeredByApp != true }
    let claims = byModel.filter { $0.claimsASave == true }
    print("\nanswers with nothing done that say something was noted, remembered or saved, as the voice says them: "
          + "\(claims.count) / \(byModel.count) turns answered by the model"
          + claims.map { "\n    · \($0.user) → “\($0.answer)”" }.joined())
    // What the model wrote so, which the app left out (`SaveClaims`): with nothing done, or before a call.
    let written = byModel.filter { claimsASave($0, written: true) }
    let leftOut = byModel.filter { $0.leftOut != nil }
    print("as the model wrote them: \(written.count) / \(byModel.count); turns with sentences left out by the app: "
          + "\(leftOut.count)" + leftOut.map { turn in
              "\n    · \(turn.user) → " + (turn.leftOut ?? []).map { "« \($0) »" }.joined(separator: " ")
                  + " → “\(turn.answer)”"
          }.joined())
}

extension Array where Element == String {
    /// The sentences in order, each once.
    fileprivate func uniquedStrings() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - A turn as the app has it, for the other benches

/// `Talk` for the other benches (journal-bench): one turn as the app has it, each call of its passes as the app read it
/// with what the app gave the model for it, and what the user heard.
struct AppTalk {
    struct Step {
        var call: ToolCall?
        /// What the app gave the model for the call, and whether it refused it.
        var result: JSONValue?
        var refused: Bool
        /// What the model wrote in this pass, besides its calls.
        var text: String
        /// With `watchCalls`: the pass as the model wrote it, and its tokens (see `Pass`); nil on a pass's later calls.
        var raw: String?
        var tokens: [WatchedToken]?
    }

    private var talk: Talk

    /// `watchCalls`: each pass's raw answer kept (`MLXChatModel.watchToolCalls`, and `watchTokens` for its tokens).
    init(model: MLXChatModel, runner: ToolRunner, calendar: MemoryCalendar, conversation: Conversation, now: Date,
         timeZone: TimeZone, maxCalls: Int, watchCalls: Bool = false)
    {
        talk = Talk(model: model, runner: runner, calendar: calendar, conversation: conversation, now: now,
                    timeZone: timeZone, watchCalls: watchCalls, maxCalls: maxCalls)
    }

    /// The turn's steps in order, its answer as the history keeps it (the model's words, then the app's sentences), and
    /// whether the model's first answer wrote nothing and it was asked once more.
    mutating func turn(_ text: String) async throws -> (steps: [Step], answer: String, askedAgain: Bool) {
        let turn = try await talk.turn(text)
        return (turn.passes.map {
            Step(call: $0.call, result: $0.result, refused: $0.refused == true, text: $0.text, raw: $0.raw,
                 tokens: $0.tokens)
        }, turn.answer, turn.askedAgain == true)
    }
}
