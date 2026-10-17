// voice-cli actions-bench — does the language model pick the right action, with the right date?
//
// Text only: no microphone, no voice, and nothing is carried out (no event, reminder or timer is created, no task
// is handed over). Each request of the corpus (Tests/Fixtures/actions-fr.json; Tests/Fixtures/agents-fr.json for
// handing tasks to Claude Code; Tests/Fixtures/web-fr.json for searching the internet) is sent to the model with the
// same system prompt and tools as in the app, at a fixed reference time, and what the app would make of the call it
// writes (the tool its name stands for, misspelled or not; the date worked out from the words it copied, the length,
// the shortcut, the words of a task's instruction or of a search) is compared with the expected one.
//
//   voice-cli actions-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                           [--corpus Tests/Fixtures/actions-fr.json] [--out measurements] [--show-prompt]
//                           [--watch-calls] [--examples app|none|file] [--web]
//                           [--searxng http://127.0.0.1:8888 [--searxng-user name]] [--record file.json]
//
// A search the model asks for is not made: the model sums up the results the corpus recorded for that request, as
// the app would have it do (nothing it writes then is carried out; the calls it writes are counted). With --searxng
// the searches are made on that SearXNG, with the model's own words (the password, if any, in the SEARXNG_PASSWORD
// environment variable), and --record writes what they found, by request, in the corpus's "recorded" shape. --web
// offers the search tool with any corpus (to check that it does not change the choice of the other tools).
//
// --watch-calls also reports, for each request, the chance the model gave to opening a tool call (at the
// first token of its answer, and at its most tempted token) and the answer as written, special tokens
// included. It slows generation a little: timings of such a run are not comparable.
// Conversations start with the example exchanges the app gives this tier's model (ActionCatalog.examples), or
// with those --examples says: "app" (the app's, on any tier), "none", or a file of exchanges (the shape of a
// case's "before", plus an optional "dateLine"; {"system": "…"} for a note from the app between them).
// --addendum <file> replaces the actions part of the system prompt (experiments without rebuilding).

import Foundation
import VoiceCore
import VoiceEngineApple

private struct Corpus: Decodable {
    var now: String
    var shortcuts: [String]
    /// The delegation tools are offered too (Claude Code switched on).
    var agents: Bool?
    /// The web search tool is offered too.
    var web: Bool?
    var cases: [Case]
    /// Earlier exchanges several cases share, by name.
    var histories: [String: [Exchange]]?
    /// What a search found for a request (by its phrase), as the app keeps it: summed up by the model when it searches.
    var recorded: [String: WebSearchResults]?

    struct Case: Decodable {
        var phrase: String
        var expected: Expected?
        var before: Before?
    }

    /// The exchanges themselves, or the name of one of `histories`.
    enum Before: Decodable {
        case exchanges([Exchange])
        case named(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                self = .named(name)
            } else {
                self = .exchanges(try container.decode([Exchange].self))
            }
        }
    }

    struct Expected: Decodable {
        var tool: String
        /// The date the call carries: "2026-10-16T15:00" (to the minute), "2026-10-16" (the day), "none".
        var when: String?
        var end: String?
        var seconds: Int?
        var name: String?
        /// Words a delegation's instruction (or a follow-up's message, or a search's keywords) must contain, whatever
        /// the accents and case.
        var mentions: [String]?
    }

    /// An earlier exchange, for corrections ("décale-le") and tasks already handed over; without a call for a plain
    /// answer ("oui").
    struct Exchange: Decodable {
        var user: String
        var call: ToolCall?
        var result: JSONValue?
        var answer: String
        /// Only for --examples (a case's earlier exchanges get the reference time's line).
        var dateLine: String?

        /// The call and its result, as the history keeps them.
        var steps: [ChatMessage] { call.map { [.call($0), .result(of: $0, result ?? .null)] } ?? [] }
    }

    func exchanges(before item: Case) -> [Exchange] {
        switch item.before {
        case nil: []
        case .exchanges(let exchanges): exchanges
        case .named(let name): histories?[name] ?? []
        }
    }
}

private struct CaseResult: Encodable {
    var phrase: String
    var expected: String
    var chosen: String
    /// The tool name as the model wrote it, when the app reads it as another tool's (`ToolNames`).
    var writtenName: String?
    var arguments: [String: JSONValue]?
    var text: String
    var toolOK: Bool
    var argumentsOK: Bool?
    /// What the app would make of the call: "2026-10-17T20:00 → 2026-10-17T21:00", "600 s".
    var resolved: String?
    /// What the app would say if it refused the call (date in the past, malformed…).
    var refusal: String?
    /// After a refusal, the call the model makes once it knows why (the app gives it that second try).
    var secondTry: String?
    var rightAfterSecondTry: Bool?
    var firstOutputMs: Double?
    var callMs: Double?
    /// From the start of the call to its tool's name read (the app's waiting phrase waits for it when a tool has its own).
    var nameReadMs: Double?
    /// With --watch-calls: the chance of opening a tool call at the first token, and at the most tempted one.
    var firstCallChance: Double?
    var bestCallChance: Double?
    var bestCallAt: Int?
    /// A search: what the model said of its results, and the calls it wrote meanwhile (the app carries out none).
    var summary: String?
    var callsWhileSumming: [String]?
    /// Whether the summary names one of the results' sites.
    var namesASite: Bool?
    /// How many tokens the results take in the model's memory.
    var resultTokens: Int?
    /// Results → first words of the summary, and its end; with --searxng, the search itself.
    var summaryFirstMs: Double?
    var summaryMs: Double?
    var searchMs: Double?
}

func runActionsBench(_ o: Options) async throws {
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/actions-fr.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: corpusURL))
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
    let clock = ContinuousClock()
    let loadStart = clock.now
    let model = try await MLXChatModel.load(directory: folder)
    print("loaded in \(clock.now - loadStart)")

    let agents = corpus.agents == true
    let web = corpus.web == true || o.web
    // In the app's order: the actions, the agents, the web search.
    let tools = ActionCatalog.calendarTools + [ActionCatalog.timer]
        + [ActionCatalog.runShortcut(names: corpus.shortcuts)].compactMap { $0 }
        + (agents ? AgentCatalog.tools(agents: [(ClaudeCode.displayName, AgentCatalog.claudeCodeDescription)], folders: [])
            : [])
        + (web ? [WebSearchCatalog.search] : [])
    var live: SearXNGProvider?
    if let text = o.searxng {
        guard let address = SearXNGProvider.address(text) else {
            throw CLIError("--searxng: expected an address like http://127.0.0.1:8888")
        }
        live = SearXNGProvider(address: address, username: o.searxngUser ?? "",
                               password: ProcessInfo.processInfo.environment["SEARXNG_PASSWORD"] ?? "")
        print("searches made on \(address.absoluteString)")
    }
    var found: [String: WebSearchResults] = [:]  // the live searches, for --record
    // As in the app (`ToolRunner.named`): a misspelled tool name is read as the tool's.
    func named(_ call: ToolCall) -> ToolCall {
        var named = call
        named.name = ToolNames.match(call.name, among: tools.map(\.name)) ?? call.name
        return named
    }
    await model.useTools(tools)
    await model.watchToolCalls(o.watchCalls)
    var conversation = Conversation()
    let exampleCall = await model.toolCallText(ActionCatalog.example.call)
    conversation.systemAddenda = [try o.addendum.map { try String(contentsOfFile: $0, encoding: .utf8) }
        ?? ActionCatalog.promptAddendum(exampleCall: exampleCall)] + (agents ? [AgentCatalog.promptAddendum] : [])
        + (web ? [WebSearchCatalog.promptAddendum] : [])
    let examples = o.examples ?? (ActionCatalog.showsExamples(on: tier) ? "app" : "none")
    switch examples {
    case "app": conversation.examples = ActionCatalog.examples(now: now, timeZone: timeZone)
    case "none": break
    default:
        // Experiment: other exchanges shown at the start of every conversation, as if they had happened, and notes
        // from the app between them ({"system": "…"}).
        let entries = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: examples)))
        conversation.examples = try entries.flatMap { entry -> [ChatMessage] in
            if case .object(let fields) = entry, let note = fields["system"]?.text { return [ChatMessage(.system, note)] }
            let exchange = try JSONDecoder().decode(Corpus.Exchange.self, from: JSONEncoder().encode(entry))
            return [Conversation.userMessage(exchange.user, language: .french, dateLine: exchange.dateLine)] + exchange.steps
                + [ChatMessage(.assistant, exchange.answer)]
        }
    }
    print("example exchanges: \(examples) (\(conversation.examples.filter { $0.role == .user }.count))")
    let dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
    let prefixStart = clock.now
    try await model.prefillBeginning(conversation.beginning)
    let prefixTokens = try await model.tokenCount(conversation.messages)
    print("system prompt with \(tools.count) tools: \(prefixTokens) tokens, computed in \(clock.now - prefixStart)\n")
    if o.showPrompt { print(try await model.promptText(conversation.messages) + "\n") }

    var results: [CaseResult] = []
    for (index, item) in corpus.cases.enumerated() {
        var history = conversation
        let before = corpus.exchanges(before: item)
        for exchange in before {
            history.record(user: Conversation.userMessage(exchange.user, language: .french, dateLine: dateLine),
                           steps: exchange.steps, assistant: exchange.answer, interrupted: false)
        }
        let request = history.messages(adding: Conversation.userMessage(item.phrase, language: .french, dateLine: dateLine))
        var text = ""
        var call: ToolCall?
        var unreadable: String?
        var firstOutput: Double?
        var callTime: Double?
        var callStart: Double?
        var nameRead: Double?
        /// A second pass (a summary, a second try) took the model's memory past this request's beginning.
        var secondPass = false
        let start = clock.now
        for try await output in model.reply(to: request) {
            if firstOutput == nil { firstOutput = milliseconds(clock.now - start) }
            switch output {
            case .text(let piece): text += piece
            case .toolCallStarted: if callStart == nil { callStart = milliseconds(clock.now - start) }
            case .toolCallNamed: if nameRead == nil { nameRead = milliseconds(clock.now - start) }
            case .toolCall(let made):
                if call == nil {
                    call = made
                    callTime = milliseconds(clock.now - start)
                }
            case .unreadableToolCall(let raw): unreadable = raw
            }
        }
        var filter = ReasoningFilter()
        text = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
        let written = call?.name
        call = call.map(named)

        let expectedTool = item.expected?.tool ?? "aucun"
        let chosen = call?.name ?? (unreadable != nil ? "illisible" : "aucun")
        var result = CaseResult(phrase: item.phrase, expected: expectedTool, chosen: chosen,
                                writtenName: written == call?.name ? nil : written, arguments: call?.arguments,
                                text: text, toolOK: chosen == expectedTool, firstOutputMs: firstOutput, callMs: callTime)
        if let callStart, let nameRead { result.nameReadMs = nameRead - callStart }
        if o.watchCalls, let chances = await model.lastToolCallChances {
            result.firstCallChance = chances.first
            result.bestCallChance = chances.best
            result.bestCallAt = chances.bestAt
        }
        // As in the app: what the user said, this request then the earlier ones.
        let context = ToolContext(now: now, timeZone: timeZone, language: .french,
                                  userSaid: [item.phrase] + before.reversed().map(\.user))
        let created = before.last
        var refusal: ToolRefusal?
        if let call, !tools.contains(where: { $0.name == call.name }) {
            // As in the app: a name that stands for no tool is refused with every tool's name.
            refusal = ToolRefusal(forModel: ToolNames.unknown(call.name, among: tools.map(\.name)),
                                  spoken: ActionPhrases.notUnderstood(.french))
            result.refusal = refusal?.forModel
        } else if let call, AgentCatalog.names.contains(call.name) {
            // Handing a task over: what the app checks, and whether the instruction keeps the user's words.
            do {
                try AgentCatalog.check(call, context: context, agents: [ClaudeCode.displayName], folders: [])
                if result.toolOK, let expected = item.expected { result.argumentsOK = mentions(call, expected) }
            } catch let refused as ToolRefusal {
                result.refusal = refused.forModel
                if result.toolOK, item.expected != nil { result.argumentsOK = false }
            }
        } else if let call, call.name == WebSearchCatalog.searchName {
            // A search: whether its keywords keep the essentials, then the model's summary of what it would find.
            do {
                try WebSearchCatalog.check(call, context: context)
                if result.toolOK, let expected = item.expected { result.argumentsOK = mentions(call, expected) }
                let query = WebSearchCatalog.query(call) ?? ""
                var results = corpus.recorded?[item.phrase]
                if let live {
                    let searchStart = clock.now
                    do {
                        results = try await live.search(query, language: .french)
                        found[item.phrase] = results
                    } catch {
                        print("      search failed: \(error)")
                    }
                    result.searchMs = milliseconds(clock.now - searchStart)
                }
                if let results {
                    secondPass = try await sumUp(call, query: query, results: results, after: request, context: context,
                                                 model: model, into: &result)
                }
            } catch let refused as ToolRefusal {
                refusal = refused
                result.refusal = refused.forModel
                if result.toolOK, item.expected != nil { result.argumentsOK = false }
            }
        } else if let call {
            do {
                let resolved = try resolve(call, created: created, context: context, shortcuts: corpus.shortcuts)
                result.resolved = resolved.description(timeZone)
                if result.toolOK, let expected = item.expected {
                    result.argumentsOK = matches(resolved, expected, context)
                }
            } catch let refused as ToolRefusal {
                refusal = refused
                result.refusal = refused.forModel
                if result.toolOK, item.expected != nil { result.argumentsOK = false }
            }
        }
        if let call, let refusal, refusal.retryable {
            // As in the app: the model sees why its call was refused and gets one more try.
            secondPass = true
            var retried: ToolCall?
            for try await output in model.reply(to: request + [.call(call), .result(of: call, ["erreur": .string(refusal.forModel)])]) {
                if case .toolCall(let made) = output, retried == nil { retried = made }
            }
            let writtenAgain = retried?.name
            retried = retried.map(named)
            result.secondTry = retried.map { describe($0, written: writtenAgain) } ?? "no call"
            if let retried, let expected = item.expected, retried.name == expectedTool,
               retried.name == WebSearchCatalog.searchName
            {
                result.rightAfterSecondTry = (try? WebSearchCatalog.check(retried, context: context)) != nil
                    && mentions(retried, expected)
            } else if let retried, let expected = item.expected, retried.name == expectedTool,
               let resolved = try? resolve(retried, created: created, context: context, shortcuts: corpus.shortcuts)
            {
                result.secondTry! += " = " + resolved.description(timeZone)
                result.rightAfterSecondTry = matches(resolved, expected, context)
            } else {
                result.rightAfterSecondTry = false
            }
        }
        results.append(result)
        let mark = result.toolOK ? (result.argumentsOK == false ? "~" : "✓") : "✗"
        let detail = call.map { describe($0, written: written) } ?? (unreadable.map { "unreadable: \($0)" } ?? "“\(text.prefix(70))”")
        print(String(format: "%3d %@ %@", index + 1, mark, item.phrase))
        let watched = result.bestCallChance.map {
            String(format: "  call chance %.0f %% first, %.0f %% at token %d", (result.firstCallChance ?? 0) * 100,
                   $0 * 100, result.bestCallAt ?? 0)
        } ?? ""
        print("      → \(detail)" + (result.resolved.map { " = \($0)" } ?? "") + (result.refusal.map { "  [refused: \($0)]" } ?? "")
              + "  \(fmt(callTime ?? firstOutput))" + watched)
        if let second = result.secondTry {
            print("      second try → \(second)" + (result.rightAfterSecondTry == true ? "  ✓" : "  ✗"))
        }
        if let summary = result.summary {
            let calls = (result.callsWhileSumming ?? []).isEmpty ? ""
                : "  [calls written while summing up, not carried out: \(result.callsWhileSumming!.joined(separator: "; "))]"
            print("      summary → “\(summary)”  \(fmt(result.summaryFirstMs))" + calls)
        }
        if o.watchCalls { print("      raw: \(await model.lastRawAnswer.debugDescription)") }
        if secondPass {
            // The next request starts again from the system prompt alone, which the model's memory, now past this
            // request's beginning, can no longer be wound back to. Back to the beginning the model keeps now, outside
            // the timings, as after "Nouvelle conversation" in the app.
            try await model.prefillBeginning(conversation.beginning)
        }
    }
    summarize(results, tier: tier, model: folder.lastPathComponent, options: o)
    if let record = o.record {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(found).write(to: URL(fileURLWithPath: record))
        print("searches recorded: \(record) (\(found.count))")
    }
}

/// The second pass of a search, as in the app: the model reads the results and answers, and nothing it writes then is
/// carried out (the calls are only counted). No results: the app says so itself, without the model. Returns whether
/// the model was asked.
private func sumUp(_ call: ToolCall, query: String, results: WebSearchResults, after request: [ChatMessage],
                   context: ToolContext, model: MLXChatModel, into result: inout CaseResult) async throws -> Bool
{
    guard !results.isEmpty else {
        result.summary = WebSearchPhrases.nothingFound(query, .french)
        return false
    }
    let forModel = WebSearchCatalog.forModel(query: query, results, context: context)
    let called = request + [.call(call)]
    result.resultTokens = try await model.tokenCount(called + [.result(of: call, forModel)]) - model.tokenCount(called)
    let clock = ContinuousClock()
    let start = clock.now
    var text = ""
    var calls: [String] = []
    for try await output in model.reply(to: request + [.call(call), .result(of: call, forModel)]) {
        switch output {
        case .text(let piece):
            if result.summaryFirstMs == nil, piece.contains(where: \.isLetter) {
                result.summaryFirstMs = milliseconds(clock.now - start)
            }
            text += piece
        case .toolCall(let made): calls.append(describe(made, written: nil))
        case .unreadableToolCall(let raw): calls.append("unreadable: \(raw)")
        case .toolCallStarted, .toolCallNamed: break
        }
    }
    result.summaryMs = milliseconds(clock.now - start)
    var filter = ReasoningFilter()
    let summary = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
    result.summary = summary.isEmpty ? "(nothing: the app says “\(WebSearchPhrases.couldNotSumUp(.french))”)" : summary
    result.callsWhileSumming = calls
    result.namesASite = namesASite(summary, results)
    return true
}

/// Whether a text names one of the results' sites: "lequipe.fr" in "D'après L'Équipe", "fr.wikipedia.org" in
/// "Selon Wikipédia" (letters and digits only, whatever the accents and case).
private func namesASite(_ text: String, _ results: WebSearchResults) -> Bool {
    func letters(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .filter { $0.isLetter || $0.isNumber }
    }
    let said = letters(text)
    let sites = ([results.answer].compactMap { $0 } + results.results).map(\.site)
    return sites.contains { site in
        site.split(separator: ".").dropLast().contains { $0.count >= 3 && said.contains(letters(String($0))) }
    }
}

/// What the app would do with a call: the moment, end, length or shortcut it would use. Throws the refusal it would
/// give. `created`: for a change, the exchange that created the item.
private struct Resolved {
    var start: Date?
    var hasTime = false
    var end: Date?
    var seconds: Int?
    var name: String?

    func description(_ timeZone: TimeZone) -> String {
        var parts: [String] = []
        if let start { parts.append(LocalDateTime.format(start, in: timeZone, withTime: hasTime)) }
        if let end { parts.append("→ " + LocalDateTime.format(end, in: timeZone, withTime: hasTime)) }
        if let seconds { parts.append("\(seconds) s") }
        if let name { parts.append("“\(name)”") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " ")
    }
}

private func resolve(_ call: ToolCall, created: Corpus.Exchange?, context: ToolContext, shortcuts: [String]) throws -> Resolved {
    try ActionCatalog.check(call, context: context, shortcuts: shortcuts)
    switch call.name {
    case ActionCatalog.createEvent.name:
        let times = try ActionCatalog.eventTimes(call, context: context)
        return Resolved(start: times.start, hasTime: !times.allDay, end: times.end)
    case ActionCatalog.createReminder.name:
        let due = try ActionCatalog.reminderDue(call, context: context)
        return Resolved(start: due?.date, hasTime: due?.hasTime ?? false)
    case ActionCatalog.readAgenda.name, ActionCatalog.listReminders.name:
        let period = try ActionCatalog.period(call, context: context, required: call.name == ActionCatalog.readAgenda.name)
        return Resolved(start: period?.0, end: period?.1)
    case ActionCatalog.changeItem.name, ActionCatalog.deleteItem.name:
        // As the app: only an item created in this conversation (the corpus's earlier exchange) can be changed, named
        // "dernier" or by its id (not, say, an example's).
        let reference = call.text("reference") ?? "dernier"
        guard case .object(let fields)? = created?.result, let id = fields["id"]?.text,
              reference == id || ["dernier", "last", "derniere", "dernière"].contains(reference.lowercased())
        else {
            throw ToolRefusal(forModel: "Aucun élément « \(reference) » créé dans cette "
                              + "conversation : seuls ceux-là peuvent être modifiés ou supprimés.",
                              spoken: ActionPhrases.nothingToChange(context.language))
        }
        guard call.name == ActionCatalog.changeItem.name else { return Resolved() }
        // The item as the app saved it.
        func saved(_ key: String) -> (date: Date, hasTime: Bool)? {
            guard case .object(let fields)? = created?.result, let text = fields[key]?.text else { return nil }
            return LocalDateTime.parse(text, in: context.timeZone)
        }
        if let start = saved("debut") {
            let end = saved("fin")?.date ?? start.date.addingTimeInterval(3600)
            let times = try ActionCatalog.changedEvent(call, start: start.date, end: end, allDay: !start.hasTime,
                                                       context: context)
            return times.map { Resolved(start: $0.start, hasTime: !$0.allDay, end: $0.end) } ?? Resolved()
        }
        let due = try ActionCatalog.changedDue(call, due: saved("echeance"), context: context)
        return Resolved(start: due?.date, hasTime: due?.hasTime ?? false)
    case ActionCatalog.timer.name:
        return Resolved(seconds: try ActionCatalog.timerSeconds(call, context: context))
    default:
        return Resolved(name: call.text("nom"))
    }
}

/// Whether a delegation's instruction (or a follow-up's message, or a search's keywords) contains the expected words,
/// whatever the accents and case.
private func mentions(_ call: ToolCall, _ expected: Corpus.Expected) -> Bool {
    guard let mentions = expected.mentions else { return true }
    func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
    let text = folded(call.text("consigne") ?? call.text("message") ?? WebSearchCatalog.query(call) ?? "")
    return mentions.allSatisfy { text.contains(folded($0)) }
}

/// Compares what the app would do (dates to the minute, or to the day; length; shortcut) with the expected one.
private func matches(_ resolved: Resolved, _ expected: Corpus.Expected, _ context: ToolContext) -> Bool {
    let timeZone = context.timeZone
    if let when = expected.when {
        if when == "none" {
            guard resolved.start == nil else { return false }
        } else {
            guard let start = resolved.start, let wanted = LocalDateTime.parse(when, in: timeZone) else { return false }
            if wanted.hasTime ? !(resolved.hasTime && start == wanted.date)
                : !context.calendar.isDate(start, inSameDayAs: wanted.date)
            {
                return false
            }
        }
    }
    if let end = expected.end {
        guard let actual = resolved.end, let wanted = LocalDateTime.parse(end, in: timeZone) else { return false }
        if wanted.hasTime ? actual != wanted.date : !context.calendar.isDate(actual, inSameDayAs: wanted.date) {
            return false
        }
    }
    if let seconds = expected.seconds, resolved.seconds != seconds { return false }
    if let name = expected.name, resolved.name != name { return false }
    return true
}

private func summarize(_ results: [CaseResult], tier: HardwareTier, model: String, options o: Options) {
    let actions = results.filter { $0.expected != "aucun" }
    let others = results.filter { $0.expected == "aucun" }
    let rightTool = actions.filter(\.toolOK).count
    let rightAction = actions.filter { $0.toolOK && $0.argumentsOK != false }.count
    let falseTriggers = others.filter { !$0.toolOK }
    let missed = actions.filter { $0.chosen == "aucun" }.count

    print("\n=== \(model) — \(results.count) requests ===")
    print(String(format: "right tool: %d / %d (%.0f %%)", rightTool, actions.count, percent(rightTool, actions.count)))
    print(String(format: "right tool and right date / length / name: %d / %d (%.0f %%)", rightAction, actions.count,
                 percent(rightAction, actions.count)))
    let rightInApp = rightAction + actions.filter { $0.rightAfterSecondTry == true }.count
    print(String(format: "  with the app's second try after a refused call: %d / %d (%.0f %%)", rightInApp,
                 actions.count, percent(rightInApp, actions.count)))
    print("requests without an action that triggered one: \(falseTriggers.count) / \(others.count)"
          + falseTriggers.map { "\n    · \($0.phrase) → \($0.chosen)" }.joined())
    print("action requests answered without a tool: \(missed)")
    print("calls the app would refuse: \(results.filter { $0.refusal != nil }.count)")
    let misspelled = results.filter { $0.writtenName != nil }
    print("misspelled tool names read as the tool's: \(misspelled.count)"
          + misspelled.map { "\n    · \($0.writtenName ?? "") → \($0.chosen)" }.joined())
    // In figures or in words ("(jeudi 15 octobre 2026 à 18:42)"): a year in brackets.
    let copied = results.filter { $0.text.range(of: #"[(\[][^()\[\]]*\b20\d{2}"#, options: .regularExpression) != nil }
    print("answers copying the date line (removed before the voice): \(copied.count) / \(results.filter { !$0.text.isEmpty }.count)")

    if results.contains(where: { $0.expected == WebSearchCatalog.searchName || $0.chosen == WebSearchCatalog.searchName }) {
        summarizeSearches(results)
    }

    // Expected / chosen.
    let optional = AgentCatalog.names.union([WebSearchCatalog.searchName])
    let tools = ["creer_evenement", "creer_rappel", "lire_agenda", "lister_rappels", "modifier_element",
                 "supprimer_element", "minuteur", "lancer_raccourci", AgentCatalog.delegateName, AgentCatalog.statusName,
                 AgentCatalog.followUpName, AgentCatalog.cancelName, WebSearchCatalog.searchName, "aucun"]
        .filter { name in !optional.contains(name) || results.contains { $0.expected == name || $0.chosen == name } }
    let others2 = Set(results.map(\.chosen)).subtracting(tools).sorted()
    let columns = tools + others2
    print("\nexpected ↓ / chosen →")
    print("".padding(toLength: 18, withPad: " ", startingAt: 0)
          + columns.map { String($0.prefix(8)).padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
    for expected in tools {
        let row = results.filter { $0.expected == expected }
        guard !row.isEmpty else { continue }
        print(expected.padding(toLength: 18, withPad: " ", startingAt: 0)
              + columns.map { chosen in
                  let n = row.filter { $0.chosen == chosen }.count
                  return (n == 0 ? "·" : String(n)).padding(toLength: 9, withPad: " ", startingAt: 0)
              }.joined())
    }

    if results.contains(where: { $0.bestCallChance != nil }) {
        // How tempted the model was: a request it missed with a high chance could be caught at that token, as long
        // as the requests without an action stay low.
        let bins: [(String, Range<Double>)] = [("<1", 0..<0.01), ("1-5", 0.01..<0.05), ("5-20", 0.05..<0.2),
                                               ("20-50", 0.2..<0.5), ("≥50", 0.5..<1.01)]
        func histogram(_ values: [Double]) -> String {
            bins.map { label, range in "\(label) %: \(values.filter(range.contains).count)" }.joined(separator: "  ")
        }
        let missedActions = actions.filter { $0.chosen == "aucun" }
        print("\nchance of opening a call (missed actions / requests without an action):")
        print("  first token   missed: " + histogram(missedActions.compactMap(\.firstCallChance)))
        print("                none:   " + histogram(others.compactMap(\.firstCallChance)))
        print("  most tempted  missed: " + histogram(missedActions.compactMap(\.bestCallChance)))
        print("                none:   " + histogram(others.compactMap(\.bestCallChance)))
    }

    let callTimes = actions.compactMap(\.callMs)
    let textTimes = others.filter(\.toolOK).compactMap(\.firstOutputMs)
    print("\ntime to a complete call: median \(fmt(median(callTimes))), worst \(fmt(callTimes.max()))")
    let nameTimes = results.compactMap(\.nameReadMs)
    print("tool's name read after the start of the call: median \(fmt(median(nameTimes))), worst \(fmt(nameTimes.max()))")
    print("time to the first word of an answer without action: median \(fmt(median(textTimes))), worst \(fmt(textTimes.max()))")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("actions-bench-\(tier.rawValue)-\(stamp).json")
    do {
        try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
        try encoder.encode(results).write(to: url)
        print("report: \(url.path)")
    } catch {
        print("could not write the report: \(error)")
    }
}

/// The web search's figures: the right decisions (to search or not), the searches by mistake and the missed ones, the
/// keywords that keep the essentials, and what the summaries did.
private func summarizeSearches(_ results: [CaseResult]) {
    let search = WebSearchCatalog.searchName
    func phrases(_ items: [CaseResult]) -> String {
        items.map { "\n    · \($0.phrase) → \($0.chosen) (expected: \($0.expected))" }.joined()
    }
    let wanted = results.filter { $0.expected == search }
    let others = results.filter { $0.expected != search }
    let mistaken = others.filter { $0.chosen == search }
    let missed = wanted.filter { $0.chosen != search }
    let right = results.count - mistaken.count - missed.count
    print(String(format: "\nweb search: right decisions (to search or not) %d / %d (%.0f %%)", right, results.count,
                 percent(right, results.count)))
    let delegations = others.filter { $0.expected == AgentCatalog.delegateName }
    let rest = others.filter { $0.expected != AgentCatalog.delegateName }
    print("  searches by mistake: \(mistaken.count) / \(others.count) — \(rest.filter { $0.chosen == search }.count) / "
          + "\(rest.count) without a search, \(delegations.filter { $0.chosen == search }.count) / \(delegations.count) "
          + "for an agent" + phrases(mistaken))
    print("  missed searches: \(missed.count) / \(wanted.count)" + phrases(missed))
    let made = wanted.filter { $0.chosen == search }
    print("  keywords keeping the essentials: \(made.filter { $0.argumentsOK == true }.count) / \(made.count)"
          + made.filter { $0.argumentsOK == false }.map { "\n    · \($0.phrase) → \(describe($0.arguments ?? [:]))" }.joined())
    let summed = results.filter { $0.chosen == search && $0.summary != nil }
    let calling = summed.filter { !($0.callsWhileSumming ?? []).isEmpty }
    print("  summaries: \(summed.count); with calls written while summing up (the app carries out none): \(calling.count)"
          + calling.map { "\n    · \($0.phrase) → \(($0.callsWhileSumming ?? []).joined(separator: "; "))" }.joined())
    let rated = summed.filter { $0.namesASite != nil }
    print("  summaries naming a site of the results: \(rated.filter { $0.namesASite == true }.count) / \(rated.count)")
    let calls = results.filter { $0.chosen == search }.compactMap(\.callMs)
    print("  time to a complete search call: median \(fmt(median(calls))), worst \(fmt(calls.max()))")
    let firstWords = summed.compactMap(\.summaryFirstMs)
    print("  results → first words of the summary: median \(fmt(median(firstWords))), worst \(fmt(firstWords.max()))")
    let tokens = summed.compactMap(\.resultTokens).map(Double.init)
    print("  the results in the model's memory: median \(median(tokens).map { String(Int($0)) } ?? "—") tokens, most "
          + "\(tokens.max().map { String(Int($0)) } ?? "—")")
    let searches = results.compactMap(\.searchMs)
    if !searches.isEmpty {
        print("  the searches themselves (--searxng): median \(fmt(median(searches))), worst \(fmt(searches.max()))")
    }
}

/// "creer_rappel {quand: …}", after the name the model wrote when the app read it as another ("crer_rappel → …").
private func describe(_ call: ToolCall, written: String?) -> String {
    (written.flatMap { $0 == call.name ? nil : "\($0) → " } ?? "") + "\(call.name) \(describe(call.arguments))"
}

private func describe(_ arguments: [String: JSONValue]) -> String {
    "{" + arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text ?? "\($0.value)")" }
        .joined(separator: ", ") + "}"
}

private func percent(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) * 100 / Double(whole) }

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
