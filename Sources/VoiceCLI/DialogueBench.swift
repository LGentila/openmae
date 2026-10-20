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
// user wanted is saved, or changed) or its sentences run out. The model samples its answers: each dialogue runs
// --repeats times (default 10), and the report counts, turn by turn, what the model did, which items its changes named
// (« dernier », "r1"), how many answers said nothing to the user, how many second tries answered in words that say it
// was done (« C'est noté », with nothing saved) and how often the goal was reached; and, for a dialogue that creates an
// item on the way that its later sentences must leave as it was, how often that item was changed or deleted.
//
//   voice-cli dialogue-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                            [--corpus Tests/Fixtures/dialogues-fr.json] [--repeats 10] [--agents] [--web]
//                            [--examples app|none|file] [--addendum file] [--watch-calls] [--out measurements]
//
// --agents and --web offer Claude Code's tools and the web search too, as in the app when they are on (nothing is
// handed over or searched: a call to them is declined). --now replaces every reference time of the corpus (a dialogue
// may have its own). --examples and --addendum are those of actions-bench. --watch-calls adds each first pass's chance
// of opening a call (at its first token, and at its most tempted token).

import Foundation
import VoiceCore
import VoiceEngineApple

private struct DialogueCorpus: Decodable {
    var now: String
    /// Claude Code switched on: its tools are offered too (as with --agents).
    var agents: Bool?
    /// The web search switched on (as with --web).
    var web: Bool?
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
    }

    /// The item the user wants saved: by this tool, its title containing `title` (whatever the accents and case), at
    /// `when` ("2026-10-16T16:00", or the day alone). With `modifier_element`, an item created earlier in the dialogue
    /// that the user wants changed: the app changed it (it did not create it), its title and date as wanted.
    struct Goal: Decodable {
        var tool: String
        var title: String?
        var when: String?
    }
}

/// One pass of the model in a turn: the first, the second try after a refused call, or the summing up of a result.
private struct Pass: Encodable {
    var text: String
    /// The call it wrote, read as the app reads it (a misspelled name as the tool's).
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
}

private struct RunResult: Encodable {
    var dialogue: String
    var run: Int
    var turns: [TurnResult]
    /// The turn (from 1) at which the goal was reached.
    var goalAt: Int?
    /// The turn (from 1) at which the item to keep (`Dialogue.keep`) was first changed or deleted.
    var keptItemTouchedAt: Int?
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
    let calendar = MemoryCalendar()
    let providers: [any ToolProvider] = [calendar, TimerTools()] + (agents ? [DryAgents()] : [])
        + (web ? [DryWebSearch()] : [])
    let runner = ToolRunner(providers: providers)
    await model.useTools(await runner.tools())
    await model.watchToolCalls(o.watchCalls)
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
        for run in 1...repeats {
            print("■ \(dialogue.name) — run \(run)/\(repeats)" + (at == now ? "" : " · at \(LocalDateTime.format(at, in: timeZone))"))
            var talk = Talk(model: model, runner: runner, calendar: calendar, conversation: base, now: at,
                            timeZone: timeZone, watchCalls: o.watchCalls)
            var result = RunResult(dialogue: dialogue.name, run: run, turns: [])
            for (index, sentence) in dialogue.turns.enumerated() {
                var turn = try await talk.turn(sentence)
                turn.goalReached = turn.passes.contains { reaches($0, dialogue.goal) }
                result.turns.append(turn)
                show(turn, index: index + 1)
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

    init(model: MLXChatModel, runner: ToolRunner, calendar: MemoryCalendar, conversation: Conversation, now: Date,
         timeZone: TimeZone, watchCalls: Bool)
    {
        self.model = model
        self.runner = runner
        self.calendar = calendar
        self.conversation = conversation
        self.now = now
        self.timeZone = timeZone
        self.watchCalls = watchCalls
    }

    mutating func turn(_ text: String) async throws -> TurnResult {
        let message = Conversation.userMessage(text, language: .french, dateLine: ActionCatalog.dateLine(now, timeZone: timeZone))
        // As the app: what the user said, this turn then the two before (their messages without the date line).
        let earlier = conversation.exchanges.filter { $0.role == .user }.suffix(2).reversed()
            .map { $0.content.components(separatedBy: "\n").first ?? "" }
        let context = ToolContext(now: now, timeZone: timeZone, language: .french, userSaid: [text] + earlier)
        var result = TurnResult(user: text, passes: [], answer: "", goalReached: false)
        var answer = ""
        var steps: [ChatMessage] = []
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
            func send(_ piece: SentenceChunker.Piece) { SpeakableText.record(piece.text, after: piece.separator, in: &answer) }
            /// As the app: the question of the refusal that gave the model its second try, said if that try says
            /// nothing.
            var refusalQuestion: String?
            /// As the app: the model asked for more than one call in this turn, which then ends saying that the app
            /// does one thing at a time.
            var askedForMore = false
            var summing: String?
            while true {
                var pass = Pass(text: "")
                var calls: [ToolCall] = []
                var moreCalls = false
                let answered = answer
                for try await output in model.reply(to: request) {
                    switch output {
                    case .text(let raw):
                        pass.text += raw
                        chunker.pieces(adding: filter.push(raw)).forEach(send)
                    case .toolCall(let call) where summing == nil: calls.append(call)
                    case .moreToolCalls where summing == nil: moreCalls = true
                    case .unreadableToolCall(let raw) where summing == nil: pass.unreadable = raw
                    default: break
                    }
                }
                chunker.pieces(adding: filter.flush()).forEach(send)
                var cleaned = ReasoningFilter()
                pass.text = (cleaned.push(pass.text) + cleaned.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.passes.isEmpty, watchCalls, let chances = await model.lastToolCallChances {
                    result.firstCallChance = chances.first
                    result.bestCallChance = chances.best
                }
                if calls.count > 1 || moreCalls { askedForMore = true }
                if let fallback = summing {
                    result.passes.append(pass)
                    chunker.remainingPieces().forEach(send)
                    if answer == answered { say(fallback) }
                    if askedForMore { say(ActionPhrases.oneThingAtATime(.french)) }
                    break
                }
                guard !calls.isEmpty || pass.unreadable != nil else {
                    result.passes.append(pass)
                    if let question = refusalQuestion {
                        chunker.remainingPieces().forEach(send)
                        if answer == answered { say(question) }
                        if askedForMore { say(ActionPhrases.oneThingAtATime(.french)) }
                    }
                    break
                }
                chunker.remainingPieces().forEach(send)
                guard let written = calls.first else {
                    result.passes.append(pass)
                    say(ActionPhrases.notUnderstood(.french))
                    break
                }
                let call = await runner.named(written)
                let creationsBefore = await calendar.creations.count
                let touchedBefore = await calendar.touched.count
                let reply = await runner.handle(call, context: context)
                if await calendar.creations.count > creationsBefore { pass.created = true }
                let touched = await calendar.touched
                if touched.count > touchedBefore { pass.touched = touched.last }
                steps += [.call(call), .result(of: call, reply.forModel)]
                pass.call = call
                pass.writtenName = written.name == call.name ? nil : written.name
                pass.result = reply.forModel
                if case .object(let fields) = reply.forModel, fields["erreur"] != nil { pass.refused = true }
                if calls.count > 1 || moreCalls { pass.moreCalls = true }
                result.passes.append(pass)
                if reply.retryable, refusalQuestion == nil {
                    // The arguments were refused: the model sees why and gets one more try.
                    refusalQuestion = reply.spoken
                    request = conversation.messages(adding: message) + steps
                    continue
                }
                if reply.modelSpeaks {
                    summing = reply.spoken
                    request = conversation.messages(adding: message) + steps
                    continue
                }
                say(reply.spoken)
                if askedForMore { say(ActionPhrases.oneThingAtATime(.french)) }
                break
            }
            chunker.remainingPieces().forEach(send)
        }
        result.answer = answer
        conversation.record(user: message, steps: steps, assistant: answer, interrupted: false)
        await model.catchUp(with: conversation.messages)
        return result
    }
}

/// Claude Code switched on, as the model sees it: its tools and its part of the prompt. Nothing is handed over: a call
/// is declined.
private struct DryAgents: ToolProvider {
    let identifier = "agents"
    func tools() async -> [ToolSpec] {
        AgentCatalog.tools(agents: [(ClaudeCode.displayName, AgentCatalog.claudeCodeDescription)], folders: [])
    }
    func promptAddendum() async -> String? { AgentCatalog.promptAddendum }
    func check(_ call: ToolCall, context: ToolContext) async throws {
        try AgentCatalog.check(call, context: context, agents: [ClaudeCode.displayName], folders: [])
    }
    func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        throw ToolRefusal(forModel: "Action non effectuée (essai).", spoken: ActionPhrases.declined(context.language),
                          retryable: false)
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
/// creer_rappel) that the app created, its title and date as wanted. Whatever call the model wrote: a change of the item
/// whose creation was just refused creates it. For modifier_element: an item that the app changed, not created.
private func reaches(_ pass: Pass, _ goal: DialogueCorpus.Goal) -> Bool {
    let change = goal.tool == ActionCatalog.changeItem.name
    let saved = change ? pass.call?.name == ActionCatalog.changeItem.name && pass.touched != nil && pass.created != true
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
    return true
}

private func folded(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
}

/// Whether the model's words say an item was saved or changed: « C'est noté », « C'est fait », « J'ai ajouté… », « Je
/// l'ai mis… », « … est enregistré ». Said in a pass without a call, nothing was.
private func saysItWasDone(_ text: String) -> Bool {
    let done = "(ajouté|créé|utilisé|mis|enregistré|noté|programmé|placé|calé|planifié|réservé|inscrit|déplacé|décalé"
        + "|modifié|changé)"
    let saved = "(noté|fait|enregistré|ajouté|programmé|créé|planifié|réservé|calé|mis|inscrit)"
    let patterns = [#"\bc'est (bien |donc )?"# + saved + #"\b"#, #"\bj'ai (bien |donc )?"# + done,
                    #"\bje (te |t')?l'ai (bien |donc )?"# + done, #"\btu as (bien )?noté\b"#,
                    #"\b(est|sont) (bien |maintenant |désormais )?"# + saved]
    let text = text.replacingOccurrences(of: "’", with: "'")
    return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
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
/// refused call answered in words that say it was done, and how many answers left the user in silence.
private func summarize(_ runs: [RunResult], corpus: DialogueCorpus) {
    func outcome(_ pass: Pass) -> String {
        guard let call = pass.call else {
            if pass.unreadable != nil { return "unreadable call" }
            return SpeakableText.clean(pass.text).isEmpty ? "nothing said" : "no call"
        }
        let creation = [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name].contains(call.name)
        return call.name + (pass.refused == true ? " (refused)" : pass.created == true && !creation ? " (created)" : "")
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
        for (index, sentence) in dialogue.turns.enumerated() {
            let turns = mine.compactMap { $0.turns.count > index ? $0.turns[index] : nil }
            guard !turns.isEmpty else { continue }
            print("turn \(index + 1) “\(sentence)” (\(turns.count) runs)")
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
            let silent = turns.filter { $0.answer.isEmpty }.count
            if silent > 0 { print("  silent answers (nothing said to the user): \(silent)") }
            let chances = turns.compactMap(\.firstCallChance)
            if !chances.isEmpty {
                print(String(format: "  call chance at the first token: median %.0f %% (%.0f–%.0f %%)",
                             (median(chances) ?? 0) * 100, (chances.min() ?? 0) * 100, (chances.max() ?? 0) * 100))
            }
        }
    }
}
