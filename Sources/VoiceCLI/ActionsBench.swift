// voice-cli actions-bench — does the language model pick the right action, with the right date?
//
// Text only: no microphone, no voice, and nothing is carried out (no event, reminder or timer is created, no task
// is handed over). Each request of the corpus (Tests/Fixtures/actions-fr.json; Tests/Fixtures/agents-fr.json for
// handing tasks to Claude Code; Tests/Fixtures/web-fr.json for searching the internet; Tests/Fixtures/sources-fr.json
// for the built-in sources: weather, quotes, travel times) is sent to the model with the
// same system prompt and tools as in the app, at a fixed reference time, and what the app would make of the call it
// writes (the tool its name stands for, misspelled or not; the date worked out from the words it copied, the length,
// the shortcut, the words of a task's instruction or of a search) is compared with the expected one.
//
//   voice-cli actions-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                           [--corpus Tests/Fixtures/actions-fr.json] [--out measurements] [--show-prompt]
//                           [--watch-calls] [--examples app|none|file] [--web] [--addendum file]
//                           [--web-addendum file] [--searxng http://127.0.0.1:8888 [--searxng-user name]]
//                           [--record file.json] [--sources] [--news] [--compare-beginnings] [--compare-requests]
//                           [--bfloat16-prompts] [--bfloat16-experts]
//
// A search the model asks for is not made: the model sums up the results the corpus recorded for that request, as
// the app would have it do (nothing it writes then is carried out; the calls it writes are counted). With --searxng
// the searches are made on that SearXNG, with the model's own words (the password, if any, in the SEARXNG_PASSWORD
// environment variable), and --record writes what they found, by request, in the corpus's "recorded" shape. --web
// offers the search tool with any corpus (to check that it does not change the choice of the other tools).
//
// The built-in sources (a corpus with "sources": true, or --sources with any corpus) work the same way: the model sums
// up what the corpus recorded for the request ("recordedSources", as the model reads it), or with --live-sources what
// the real services answer (Open-Meteo, the ECB's rates, CoinGecko, Apple's maps; "here" is the corpus's "here"), timed;
// --record-sources writes those answers, by request, in the corpus's shape.
//
// The news' tool, lire_nouvelles (a corpus with "news": true, or --news with any corpus, to check that it does not change
// the choice of the other tools), takes no argument: choosing it is all there is to check. Tests/Fixtures/news-fr.json.
// --news-addendum <file> replaces its part of the system prompt.
//
// --watch-calls also reports, for each request, the chance the model gave to opening a tool call (at the
// first token of its answer, and at its most tempted token) and the answer as written, special tokens
// included. It slows generation a little: timings of such a run are not comparable.
// Conversations start with the example exchanges the app gives this tier's model (ActionCatalog.examples), or
// with those --examples says: "app" (the app's, on any tier), "none", or a file of exchanges (the shape of a
// case's "before", plus an optional "dateLine"; {"system": "…"} for a note from the app between them).
// --addendum <file> replaces the actions part of the system prompt, --web-addendum <file> the web search's
// (experiments without rebuilding).
// --no-actions leaves the actions out (their tools, their part of the prompt and their example exchanges), as the app
// has Claude Code, the web search or the built-in sources on their own when the actions are off: the prompt then only
// says what the date line is, and a request whose tool is not offered expects no call.
// A case's earlier exchanges ("before") may hold a search: its call, and what it found ("found", in the "recorded"
// shape), which the model reads as the app gives it. A search made after one of them is checked for keywords of its own.
// --compare-beginnings generates nothing: it compares the beginning of the conversations (system prompt, tools, examples)
// as the app computes it at load and again when the tools change (in float32, then rounded), the ways it was computed
// before (in bfloat16, as the conversations), and a float32 reference with every weight converted: the model's memory
// layer by layer, and each request's chance of a call at its first token, read as the app reads it (from the state at
// load, the same as --watch-calls).
// --compare-requests generates nothing either: from the beginning the app keeps, it reads each request's first token in
// several ways, against the same float32 reference (every weight converted, the beginning and the request in one pass):
// the request's new tokens in one pass, in bfloat16 as the app computed them before and in float32 as it does now (the
// same as --watch-calls), with a mixture-of-experts model (Gemma 4 26B) also with its experts' products in the other type
// (float32 in the app, bfloat16 with --bfloat16-experts); and for a request with earlier exchanges, those first on their
// own (as the history computed ahead, 64 tokens at a time, or in one pass as when a request goes back to the beginning),
// in bfloat16 or in float32.
// --bfloat16-prompts computes the requests' new tokens and the history in bfloat16, as the app did before (comparisons in
// one build; the beginning stays in float32). --bfloat16-experts computes a mixture-of-experts model's experts' products
// in bfloat16 as the requests and the history are computed in float32 (the app computes them in float32 too).

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
    /// The built-in sources' tools are offered too (weather, quotes, travel times).
    var sources: Bool?
    /// Where "here" is for them.
    var here: Place?
    /// The memory's tool is offered too (`memoire`, with the journal), with this sheet in the prompt.
    var memory: Bool?
    var memorySheet: [String]?
    /// What a source answered for a request (by its phrase), as the model reads it: summed up by the model.
    var recordedSources: [String: JSONValue]?
    /// The news' tool is offered too (a source of received information exists).
    var news: Bool?

    struct Case: Decodable {
        var phrase: String
        var expected: Expected?
        /// `expected` written as a list: the actions the request asks for, in the order said (several at once).
        var expectedList: [Expected]?
        var before: Before?

        private enum CodingKeys: String, CodingKey { case phrase, expected, before }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phrase = try c.decode(String.self, forKey: .phrase)
            before = try c.decodeIfPresent(Before.self, forKey: .before)
            if let list = try? c.decode([Expected].self, forKey: .expected) {
                expectedList = list
                expected = list.first
            } else {
                expected = try c.decodeIfPresent(Expected.self, forKey: .expected)
            }
        }
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
        /// The app must refuse the call: "past" for a date already gone, "weekday" for a weekday that is not the date's.
        /// The call is still expected, with the user's words (the app checks the date, not the model), and `when` is the
        /// date they give.
        var refused: String?
        /// A built-in source: the call names no place (where the user is); the instrument the app must find ("EUR/USD",
        /// "bitcoin/EUR"); the travel mode ("car", "transit"). `when` is then the forecast's day ("none" for now) or the
        /// time to arrive by.
        var here: Bool?
        var instrument: String?
        var mode: String?
        /// The memory: the action expected (`retenir`, `chercher`, `oublier`).
        var action: String?
    }

    /// An earlier exchange, for corrections ("décale-le"), tasks already handed over and searches already made;
    /// without a call for a plain answer ("oui").
    struct Exchange: Decodable {
        var user: String
        var call: ToolCall?
        var result: JSONValue?
        /// A search's results, in the "recorded" shape: its result is then what the app gives the model of them.
        var found: WebSearchResults?
        var answer: String
        /// Only for --examples (a case's earlier exchanges get the reference time's line).
        var dateLine: String?

        /// The call and its result, as the history keeps them.
        func steps(_ context: ToolContext) -> [ChatMessage] {
            guard let call else { return [] }
            let read = found.map { WebSearchCatalog.forModel(query: WebSearchCatalog.query(call) ?? "", $0, context: context) }
            return [.call(call), .result(of: call, result ?? read ?? .null)]
        }
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
    /// The model went on to another call after this one (the app carries out one action per request).
    var moreCalls: Bool?
    var text: String
    var toolOK: Bool
    var argumentsOK: Bool?
    /// What the app would make of the call: "2026-10-17T20:00 → 2026-10-17T21:00", "600 s".
    var resolved: String?
    /// What the app would say if it refused the call (date in the past, malformed…).
    var refusal: String?
    /// After a refusal, the call the model makes once it knows why (the app gives it that second try), or what it says.
    var secondTry: String?
    /// A call refused when it should not have been, made right at the second try; a refusal the corpus expects, followed
    /// by no call (the model asks the user) or by a call the app refuses too.
    var rightAfterSecondTry: Bool?
    var firstOutputMs: Double?
    var callMs: Double?
    /// From the start of the call to its tool's name read (the app's waiting phrase waits for it when a tool has its own).
    var nameReadMs: Double?
    /// The GPU memory peak during the request (GB, the weights included).
    var peakGB: Double?
    /// With --watch-calls: the chance of opening a tool call at the first token, and at the most tempted one.
    var firstCallChance: Double?
    var bestCallChance: Double?
    var bestCallAt: Int?
    /// The keywords of the searches in the case's earlier exchanges, and whether this request's search uses the same
    /// ones again (whatever the accents, case and spacing).
    var earlierSearches: [String]?
    var sameKeywordsAsBefore: Bool?
    /// A search: what the model said of its results, and the calls it wrote meanwhile (the app carries out none).
    var summary: String?
    var callsWhileSumming: [String]?
    /// It wrote a call and nothing else, and summed up once more (as the app has it do).
    var summedUpAgain: Bool?
    /// Whether the summary names one of the results' sites.
    var namesASite: Bool?
    /// How many tokens the results take in the model's memory.
    var resultTokens: Int?
    /// Results → first words of the summary, and its end; with --searxng, the search itself.
    var summaryFirstMs: Double?
    var summaryMs: Double?
    var searchMs: Double?
    /// A built-in source: whether the summary keeps a number of the data as written, and, for a quote, says when it is
    /// from.
    var keepsNumber: Bool?
    var saysWhen: Bool?
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

    let actions = !o.noActions
    let agents = corpus.agents == true
    let web = corpus.web == true || o.web
    let sources = corpus.sources == true || o.sources
    if !actions {
        guard o.addendum == nil else { throw CLIError("--addendum replaces the actions part: not with --no-actions") }
        print("the actions left out, as in the app when they are off")
    }
    let news = corpus.news == true || o.news
    let memory = corpus.memory == true || o.memory
    let sheet = corpus.memorySheet ?? []
    // In the app's order: the actions, the agents, the web search, the built-in sources, the news, the memory (last).
    let tools = (actions ? ActionCatalog.calendarTools(on: tier) + [ActionCatalog.timer]
        + [ActionCatalog.runShortcut(names: corpus.shortcuts)].compactMap { $0 } : [])
        + (agents ? AgentCatalog.tools(agents: [(ClaudeCode.displayName, AgentCatalog.claudeCodeDescription)], folders: [])
            : [])
        + (web ? [WebSearchCatalog.search] : [])
        + (sources ? BuiltInSources.tools : [])
        + (news ? [NewsCatalog.read] : [])
        + (memory ? [MemoryCatalog.tool(journal: true)] : [])
    let here = FixedHere(corpus.here)
    let liveSources: [String: any ToolProvider] = o.liveSources ? [
        WeatherCatalog.name: WeatherTools(on: true, here: here),
        QuoteCatalog.name: QuoteTools(on: true),
        TravelTimeCatalog.name: TravelTimeTools(on: true, here: here, estimator: MapKitTravel()),
    ] : [:]
    if o.liveSources { print("built-in sources asked for real, here = \(corpus.here?.name ?? "unknown")") }
    var answered: [String: JSONValue] = [:]  // the live sources' answers, for --record-sources
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
    await model.computePromptsInFloat32(!o.bfloat16Prompts)
    if o.bfloat16Prompts { print("requests and history computed in bfloat16 (--bfloat16-prompts)") }
    await model.computeExpertsInHalfPrecision(o.bfloat16Experts)
    if o.bfloat16Experts { print("experts' products in bfloat16 in the requests and the history (--bfloat16-experts)") }
    let maxCalls = max(1, o.maxCalls ?? ActionCatalog.actionsPerRequest(on: tier))
    await model.limitToolCalls(maxCalls)
    print("calls carried out in one request: \(maxCalls) at most")
    var conversation = Conversation()
    let exampleCall = await model.toolCallText(ActionCatalog.example.call)
    // As `VoicePipeline` puts it together: the actions' part, or without them what the date line is; then the tools'.
    let actionsPart: String
    if !actions {
        actionsPart = ActionCatalog.dateLineRule
    } else if let file = o.addendum {
        actionsPart = try String(contentsOfFile: file, encoding: .utf8)
    } else {
        actionsPart = ActionCatalog.promptAddendum(exampleCall: exampleCall)
    }
    conversation.systemAddenda = [actionsPart] + (agents ? [AgentCatalog.promptAddendum] : [])
        + (web ? [try o.webAddendum.map { try String(contentsOfFile: $0, encoding: .utf8) }
            ?? WebSearchCatalog.promptAddendum] : [])
        + (sources ? [WeatherCatalog.promptAddendum, QuoteCatalog.promptAddendum, TravelTimeCatalog.promptAddendum] : [])
        + (news ? [try o.newsAddendum.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? NewsCatalog.promptAddendum]
            : [])
        + (memory ? [MemoryCatalog.promptAddendum(sheet: sheet, journal: true)] : [])
    if memory { print("memory: on, with the journal, \(sheet.count) entries in the sheet") }
    let examples = o.examples ?? (actions && ActionCatalog.showsExamples(on: tier) ? "app" : "none")
    conversation.examples = try exampleExchanges(examples, now: now, timeZone: timeZone)
    print("example exchanges: \(examples) (\(conversation.examples.filter { $0.role == .user }.count))")
    let dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
    let reference = ToolContext(now: now, timeZone: timeZone, language: .french)
    let prefixStart = clock.now
    try await model.prefillBeginning(conversation.beginning)
    let prefixTokens = try await model.tokenCount(conversation.messages)
    print("system prompt with \(tools.count) tools: \(prefixTokens) tokens, computed in \(clock.now - prefixStart)"
          + String(format: " (GPU memory peak %.2f GB)\n", await model.lastBeginning?.peakGB ?? 0))
    if o.showPrompt { print(try await model.promptText(conversation.messages) + "\n") }
    if o.compareBeginnings {
        try await compareBeginnings(corpus, conversation: conversation, tools: tools, dateLine: dateLine,
                                    context: reference, model: model, options: o)
        return
    }
    if o.compareRequests {
        try await compareRequests(corpus, conversation: conversation, dateLine: dateLine, context: reference,
                                  model: model, folder: folder, options: o)
        return
    }

    if corpus.cases.contains(where: { $0.expectedList != nil }) {
        try await runSeveralActions(corpus, conversation: conversation, tools: tools, dateLine: dateLine, now: now,
                                    timeZone: timeZone, model: model, maxCalls: maxCalls, tier: tier,
                                    modelName: folder.lastPathComponent, options: o)
        return
    }

    var results: [CaseResult] = []
    for (index, item) in corpus.cases.enumerated() {
        let before = corpus.exchanges(before: item)
        let request = caseRequest(item, in: conversation, corpus: corpus, dateLine: dateLine, context: reference)
        var text = ""
        var call: ToolCall?
        var moreCalls = false
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
                } else {
                    moreCalls = true
                }
            case .moreToolCalls: moreCalls = true
            case .unreadableToolCall(let raw): unreadable = raw
            }
        }
        var filter = ReasoningFilter()
        text = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
        let written = call?.name
        call = call.map(named)

        var expectedTool = item.expected?.tool ?? "aucun"
        // Without the actions, a request for one of them expects no call: no tool does it.
        if !actions, !tools.contains(where: { $0.name == expectedTool }) { expectedTool = "aucun" }
        let chosen = call?.name ?? (unreadable != nil ? "illisible" : "aucun")
        var result = CaseResult(phrase: item.phrase, expected: expectedTool, chosen: chosen,
                                writtenName: written == call?.name ? nil : written, arguments: call?.arguments,
                                moreCalls: moreCalls ? true : nil, text: text, toolOK: chosen == expectedTool,
                                firstOutputMs: firstOutput, callMs: callTime)
        if let callStart, let nameRead { result.nameReadMs = nameRead - callStart }
        result.peakGB = await model.lastRequestPeakGB
        let earlierSearches = before.compactMap(\.call).filter { $0.name == WebSearchCatalog.searchName }
            .compactMap(WebSearchCatalog.query)
        if !earlierSearches.isEmpty { result.earlierSearches = earlierSearches }
        if o.watchCalls, let chances = await model.lastToolCallChances {
            result.firstCallChance = chances.first
            result.bestCallChance = chances.best
            result.bestCallAt = chances.bestAt
        }
        // As in the app: what the user said, this request then the earlier ones.
        let context = ToolContext(now: now, timeZone: timeZone, language: .french,
                                  userSaid: moreCalls ? [] : [item.phrase] + before.reversed().map(\.user))
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
                if !earlierSearches.isEmpty {
                    result.sameKeywordsAsBefore = earlierSearches.map(keywords).contains(keywords(query))
                }
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
        } else if let call, call.name == NewsCatalog.readName {
            // The news: no argument, nothing for the app to refuse; the app reads them itself.
        } else if let call, call.name == MemoryCatalog.name {
            // The memory: the action, the words the corpus expects, and whether the app accepts the call (a fact the
            // user did not say is refused).
            let action = MemoryCatalog.action(call)
            result.resolved = action?.rawValue ?? "no action"
            do {
                try checkMemory(call, sheet: sheet, context: context)
                if result.toolOK, let expected = item.expected {
                    result.argumentsOK = (expected.action == nil || expected.action == action?.rawValue)
                        && memoryMentions(call, expected)
                }
            } catch let refused as ToolRefusal {
                result.refusal = refused.forModel
                if result.toolOK, item.expected != nil { result.argumentsOK = false }
            }
        } else if let call, BuiltInSources.names.contains(call.name) {
            // A built-in source: whether the app accepts the call and reads it as the corpus expects, then the model's
            // summary of what the source answered (recorded, or asked for real).
            do {
                try checkSource(call, context: context)
                if result.toolOK, let expected = item.expected {
                    result.argumentsOK = mentions(call, expected) && sourceMatches(call, expected, context)
                }
                var forModel = corpus.recordedSources?[item.phrase]
                if let provider = liveSources[call.name] {
                    let sourceStart = clock.now
                    do {
                        forModel = try await provider.perform(call, context: context).forModel
                        answered[item.phrase] = forModel
                    } catch let refused as ToolRefusal {
                        forModel = nil
                        result.refusal = refused.forModel
                    }
                    result.searchMs = milliseconds(clock.now - sourceStart)
                }
                if let forModel {
                    secondPass = try await sumUpSource(call, forModel: forModel, after: request, model: model,
                                                       into: &result)
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
                    result.argumentsOK = expected.refused == nil && matches(resolved, expected, context)
                }
            } catch let refused as ToolRefusal {
                refusal = refused
                result.refusal = refused.forModel
                if result.toolOK, let expected = item.expected {
                    result.argumentsOK = refusedAsExpected(call, refused, expected, context)
                }
            }
        }
        if let call, let refusal, refusal.retryable {
            // As in the app: the model sees why its call was refused and gets one more try.
            secondPass = true
            var retried: ToolCall?
            var said = ""
            for try await output in model.reply(to: request + [.call(call), .result(of: call, refusal.result(for: call))]) {
                if case .toolCall(let made) = output, retried == nil { retried = made }
                if case .text(let piece) = output, retried == nil { said += piece }
            }
            let writtenAgain = retried?.name
            retried = retried.map(named)
            var saidFilter = ReasoningFilter()
            said = (saidFilter.push(said) + saidFilter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
            result.secondTry = retried.map { describe($0, written: writtenAgain) } ?? "no call: “\(said)”"
            if result.argumentsOK == true {
                // The refusal the corpus expects: the model must not slip a date of its own past the app.
                let refusedAgain = retried.map { again in
                    (try? resolve(again, created: created, context: context, shortcuts: corpus.shortcuts)) == nil
                } ?? true
                result.rightAfterSecondTry = refusedAgain
            } else if let retried, let expected = item.expected, retried.name == expectedTool,
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
              + (moreCalls ? "  [then another call, not carried out]" : "")
              + "  \(fmt(callTime ?? firstOutput))" + watched)
        if let second = result.secondTry {
            print("      second try → \(second)" + (result.rightAfterSecondTry == true ? "  ✓" : "  ✗"))
        }
        if let summary = result.summary {
            let calls = (result.callsWhileSumming ?? []).isEmpty ? ""
                : "  [calls written while summing up, not carried out: \(result.callsWhileSumming!.joined(separator: "; "))]"
            print("      summary → “\(summary)”  \(fmt(result.summaryFirstMs))" + calls
                  + (result.summedUpAgain == true ? "  [summed up once more after a call alone]" : ""))
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
    if let record = o.recordSources {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(answered).write(to: URL(fileURLWithPath: record))
        print("sources' answers recorded: \(record) (\(answered.count))")
    }
}

/// The exchanges every conversation starts with, as --examples says: "app" (the app's, `ActionCatalog.examples`), "none",
/// or a file of exchanges shown as if they had happened (the shape of a case's "before", plus an optional "dateLine"), with
/// notes from the app between them ({"system": "…"}).
func exampleExchanges(_ examples: String, now: Date, timeZone: TimeZone) throws -> [ChatMessage] {
    switch examples {
    case "app": return ActionCatalog.examples(now: now, timeZone: timeZone)
    case "none": return []
    default:
        let entries = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: examples)))
        return try entries.flatMap { entry -> [ChatMessage] in
            if case .object(let fields) = entry, let note = fields["system"]?.text { return [ChatMessage(.system, note)] }
            let exchange = try JSONDecoder().decode(Corpus.Exchange.self, from: JSONEncoder().encode(entry))
            return [Conversation.userMessage(exchange.user, language: .french, dateLine: exchange.dateLine)]
                + exchange.steps(ToolContext(now: now, timeZone: timeZone, language: .french))
                + [ChatMessage(.assistant, exchange.answer)]
        }
    }
}

/// A case's request as the app would send it: the conversation, the case's earlier exchanges, then its phrase.
private func caseRequest(_ item: Corpus.Case, in conversation: Conversation, corpus: Corpus, dateLine: String,
                         context: ToolContext) -> [ChatMessage]
{
    var history = conversation
    for exchange in corpus.exchanges(before: item) {
        history.record(user: Conversation.userMessage(exchange.user, language: .french, dateLine: dateLine),
                       steps: exchange.steps(context), assistant: exchange.answer, interrupted: false)
    }
    return history.messages(adding: Conversation.userMessage(item.phrase, language: .french, dateLine: dateLine))
}

/// --compare-beginnings: the beginning computed at load and again when the tools changed and changed back, as in the app,
/// other ways of computing it and a float32 reference (see `MLXChatModel.compareBeginnings`): every pair of caches, then
/// each request's chance of a call at its first token from each, and the requests whose first-token decision (a call or
/// not, the more likely of the two) changes.
private func compareBeginnings(_ corpus: Corpus, conversation: Conversation, tools: [ToolSpec], dateLine: String,
                               context: ToolContext, model: MLXChatModel, options o: Options) async throws
{
    guard let atLoad = await model.beginningState(named: "at load") else { throw CLIError("no beginning kept") }
    let clock = ContinuousClock()
    for (label, offered) in [("one tool less", Array(tools.dropLast())), ("the tools back", tools)] {
        await model.useTools(offered)
        let started = clock.now
        try await model.prefillBeginning(conversation.beginning)
        let computed = await model.lastBeginning
        print("tools changed (\(label)): the beginning computed again in \(clock.now - started)"
              + String(format: " (%d tokens, GPU memory peak %.2f GB)", computed?.computed ?? 0, computed?.peakGB ?? 0))
    }
    guard let toolsChanged = await model.beginningState(named: "tools changed") else { throw CLIError("no beginning kept") }
    let requests = corpus.cases.map {
        caseRequest($0, in: conversation, corpus: corpus, dateLine: dateLine, context: context)
    }
    let start = clock.now
    let comparison = try await model.compareBeginnings([atLoad, toolsChanged], requests: requests)
    print("compared in \(clock.now - start)\n")
    let names = comparison.names
    let reference = names.count - 1
    for (index, name) in names.enumerated() { print("  [\(index)] \(name)") }
    let unroundedFirst = comparison.unrounded.compactMap(\.firstDifference).min()
    print("\nthe app's way before its rounding ↔ the reference [\(reference)]: "
          + (unroundedFirst.map { "largest ‖a − b‖ / ‖b‖ " + scientific(comparison.unrounded.map(\.relative).max())
              + ", first difference at position \($0)" } ?? "identical in every layer"))

    print("\nthe model's memory, pair by pair (‖a − b‖ / ‖b‖, largest over the layers; first position that differs):")
    for pair in comparison.pairs {
        let sliding = pair.layers.filter(\.sliding)
        let full = pair.layers.filter { !$0.sliding }
        let first = pair.layers.compactMap(\.firstDifference).min()
        print("  [\(pair.a)] ↔ [\(pair.b)]  sliding " + scientific(sliding.map(\.relative).max()) + " (\(span(sliding)))"
              + "  full " + scientific(full.map(\.relative).max()) + " (\(span(full)))  "
              + (first.map { "first difference at position \($0)" } ?? "identical"))
    }
    if let pair = comparison.pairs.first(where: { $0.a == 0 && $0.b == 1 }),
       pair.layers.contains(where: { $0.firstDifference != nil })
    {
        print("\n[0] ↔ [1] layer by layer (over all positions; median position; positions over 0.5):")
        for layer in pair.layers {
            print("  layer \(layer.layer) \(layer.sliding ? "sliding" : "full")  " + scientific(layer.relative) + "; "
                  + scientific(layer.typical) + String(format: "; %.1f %%  ", layer.far * 100)
                  + (layer.firstDifference.map { "from position \($0)" } ?? "identical"))
        }
    }
    print("\nlast layer against the reference [\(reference)] (over all positions; median position; positions over 0.5):")
    for pair in comparison.pairs where pair.b == reference {
        guard let last = pair.layers.last else { continue }
        print("  [\(pair.a)] " + scientific(last.relative) + "; " + scientific(last.typical)
              + String(format: "; %.1f %%", last.far * 100))
    }

    print("\nchance of a call at the first token (%), from beginnings [0] … [\(reference)]:")
    let calls = comparison.firstTokens.map { $0.map(\.callChance) }
    func decides(_ chance: Double) -> Bool { chance >= 0.5 }
    for (item, row) in zip(corpus.cases, calls) {
        let chances = row.map { String(format: "%3.0f", $0 * 100) }.joined(separator: " ")
        print("  \(chances)  \(Set(row.map(decides)).count > 1 ? "≠" : " ") \(item.phrase)")
    }

    print("\nagainst the reference [\(reference)], over \(requests.count) requests:")
    for index in names.indices where index != reference {
        let flips = calls.filter { decides($0[index]) != decides($0[reference]) }.count
        let far = calls.filter { abs($0[index] - $0[reference]) >= 0.2 }.count
        let tops = comparison.firstTokens.filter { $0[index].top != $0[reference].top }.count
        let divergences = comparison.firstTokens.map { $0[index].divergence }
        let offBy = calls.map { abs($0[index] - $0[reference]) }.reduce(0, +)
        print("  [\(index)] decision changed: \(flips) · call chance 20 points or more away: \(far) · other first token: "
              + "\(tops) · call chance off by " + String(format: "%.2f", offBy) + " in all · divergence median "
              + scientific(median(divergences)) + ", max " + scientific(divergences.max()) + " nats")
    }
    let moved = zip(corpus.cases, calls).filter { abs($0.1[0] - $0.1[1]) >= 0.2 }
    let flipped = calls.filter { decides($0[0]) != decides($0[1]) }.count
    print("\n[0] ↔ [1]: decision changed for \(flipped) / \(requests.count) requests, call chance moved by 20 points or "
          + "more for \(moved.count)"
          + moved.map { item, row in
              String(format: "\n    · %.0f %% → %.0f %% (reference %.0f %%)  ", row[0] * 100, row[1] * 100,
                     row[reference] * 100) + item.phrase
          }.joined())

    struct Layer: Encodable {
        var layer: Int
        var sliding: Bool
        var positions: [Int]
        var relative: Double
        var typical: Double
        var far: Double
        var firstDifference: Int?
    }
    struct Pair: Encodable {
        var a: Int
        var b: Int
        var layers: [Layer]
    }
    struct Request: Encodable {
        var phrase: String
        var expected: String
        var callChances: [Double]
        var tops: [String]
        var divergences: [Double]
    }
    struct Report: Encodable {
        var model: String
        var corpus: String
        var states: [String]
        var pairs: [Pair]
        /// The app's way before its rounding, against the reference.
        var unrounded: [Layer]
        var requests: [Request]
    }
    func layers(_ layers: [MLXChatModel.LayerDifference]) -> [Layer] {
        layers.map {
            Layer(layer: $0.layer, sliding: $0.sliding, positions: [$0.positions.lowerBound, $0.positions.upperBound],
                  relative: $0.relative, typical: $0.typical, far: $0.far, firstDifference: $0.firstDifference)
        }
    }
    let report = Report(
        model: o.llm ?? "", corpus: o.corpus ?? "", states: names,
        pairs: comparison.pairs.map { Pair(a: $0.a, b: $0.b, layers: layers($0.layers)) },
        unrounded: layers(comparison.unrounded),
        requests: zip(corpus.cases, comparison.firstTokens).map { item, row in
            Request(phrase: item.phrase, expected: item.expected?.tool ?? "aucun", callChances: row.map(\.callChance),
                    tops: row.map(\.top), divergences: row.map(\.divergence))
        })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("compare-beginnings-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(report).write(to: url)
    print("report: \(url.path)")
}

/// --compare-requests: each request's first token from the beginning the app keeps, in several ways (see
/// `MLXChatModel.compareRequests`), against the float32 reference: how far each way's chances of a call are from the
/// reference's, over all requests and over those with earlier exchanges (where the ways differ), and from the app's own
/// way (one pass in float32) there.
private func compareRequests(_ corpus: Corpus, conversation: Conversation, dateLine: String, context: ToolContext,
                             model: MLXChatModel, folder: URL, options o: Options) async throws
{
    let requests = corpus.cases.map {
        caseRequest($0, in: conversation, corpus: corpus, dateLine: dateLine, context: context)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let comparison = try await model.compareRequests(requests)
    print("compared in \(clock.now - start)\n")
    let names = comparison.names
    let reference = names.count - 1
    let app = comparison.app
    for (index, name) in names.enumerated() { print("  [\(index)] \(name)") }
    func decides(_ chance: Double) -> Bool { chance >= 0.5 }

    print("\nchance of a call at the first token (%), ways [0] … [\(reference)] (· where a way does not apply):")
    for (item, row) in zip(corpus.cases, comparison.firstTokens) {
        let chances = row.map { $0.map { String(format: "%5.1f", $0.callChance * 100) } ?? "    ·" }.joined(separator: " ")
        let decisions = Set(row.compactMap { $0.map { decides($0.callChance) } })
        print("  \(chances)  \(decisions.count > 1 ? "≠" : " ") \(item.phrase)")
    }

    /// `rows`: the requests compared; `against`: the way compared with.
    func compare(_ index: Int, against other: Int, over rows: [[MLXChatModel.FirstToken?]]) -> String {
        let pairs = rows.compactMap { row -> (MLXChatModel.FirstToken, MLXChatModel.FirstToken)? in
            guard let a = row[index], let b = row[other] else { return nil }
            return (a, b)
        }
        let flips = pairs.filter { decides($0.0.callChance) != decides($0.1.callChance) }.count
        let far = pairs.filter { abs($0.0.callChance - $0.1.callChance) >= 0.2 }.count
        let tops = pairs.filter { $0.0.top != $0.1.top }.count
        let offBy = pairs.map { abs($0.0.callChance - $0.1.callChance) }.reduce(0, +)
        let largest = pairs.map { abs($0.0.callChance - $0.1.callChance) }.max() ?? 0
        var line = "decision changed: \(flips) · call chance 20 points or more away: \(far) · other first token: \(tops)"
            + String(format: " · call chance off by %.3f in all (largest %.1f points)", offBy, largest * 100)
        if other == reference {
            let divergences = pairs.map(\.0.divergence)
            line += " · divergence median " + scientific(median(divergences)) + ", max " + scientific(divergences.max())
                + " nats"
        }
        return line + " (\(pairs.count) requests)"
    }
    let rows = comparison.firstTokens
    let withHistory = rows.filter { $0.allSatisfy { $0 != nil } }  // the ways with earlier exchanges apply
    // The ways that apply to every request: the request's new tokens in one pass.
    let onePass = names.indices.filter { index in index != reference && rows.allSatisfy { $0[index] != nil } }
    print("\nagainst the reference [\(reference)], over all \(rows.count) requests:")
    for index in onePass { print("  [\(index)] " + compare(index, against: reference, over: rows)) }
    print("\nthe \(withHistory.count) requests with earlier exchanges, against the reference [\(reference)]:")
    for index in names.indices where index != reference {
        print("  [\(index)] " + compare(index, against: reference, over: withHistory))
    }
    print("\nthe same requests, against the app's way [\(app)]:")
    for index in names.indices where index != reference && index != app {
        print("  [\(index)] " + compare(index, against: app, over: withHistory))
    }

    struct Request: Encodable {
        var phrase: String
        var expected: String
        var callChances: [Double?]
        var tops: [String?]
        var divergences: [Double?]
    }
    struct Report: Encodable {
        var model: String
        var corpus: String
        var ways: [String]
        var requests: [Request]
    }
    let report = Report(
        model: folder.lastPathComponent, corpus: o.corpus ?? "", ways: names,
        requests: zip(corpus.cases, rows).map { item, row in
            Request(phrase: item.phrase, expected: item.expected?.tool ?? "aucun", callChances: row.map { $0?.callChance },
                    tops: row.map { $0?.top }, divergences: row.map { $0?.divergence })
        })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("compare-requests-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(report).write(to: url)
    print("report: \(url.path)")
}

/// The positions the layers compared: "0-1584", or "561-1584" for a sliding window.
private func span(_ layers: [MLXChatModel.LayerDifference]) -> String {
    guard let positions = layers.first?.positions else { return "—" }
    return "positions \(positions.lowerBound)-\(positions.upperBound - 1)"
}

private func scientific(_ value: Double?) -> String {
    value.map { $0 == 0 ? "0" : String(format: "%.1e", $0) } ?? "—"
}

/// The second pass of a search, as in the app: the model reads the results and answers, and nothing it writes then is
/// carried out (the calls are only counted). A call and nothing else: as in the app, the model is told it is not carried
/// out and sums up once more. No results: the app says so itself, without the model. Returns whether the model was asked.
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
    var calls: [String] = []
    var steps: [ChatMessage] = [.call(call), .result(of: call, forModel)]
    var summary = ""
    for pass in 1...2 {
        var text = ""
        var ignored: ToolCall?
        for try await output in model.reply(to: request + steps) {
            switch output {
            case .text(let piece):
                if result.summaryFirstMs == nil, piece.contains(where: \.isLetter) {
                    result.summaryFirstMs = milliseconds(clock.now - start)
                }
                text += piece
            case .toolCall(let made):
                calls.append(describe(made, written: nil))
                if ignored == nil { ignored = made }
            case .moreToolCalls: calls.append("another call, not written")
            case .unreadableToolCall(let raw): calls.append("unreadable: \(raw)")
            case .toolCallStarted, .toolCallNamed: break
            }
        }
        var filter = ReasoningFilter()
        summary = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.isEmpty, let ignored, pass == 1 else { break }
        result.summedUpAgain = true
        steps += [.call(ignored), .result(of: ignored, ["erreur": .string(ToolOutcome.noCallWhileSummingUp)])]
    }
    result.summaryMs = milliseconds(clock.now - start)
    result.summary = summary.isEmpty ? "(nothing: the app says “\(WebSearchPhrases.couldNotSumUp(.french))”)" : summary
    result.callsWhileSumming = calls
    result.namesASite = namesASite(summary, results)
    return true
}

/// The summing up of a built-in source's data, as in the app: the model reads it and answers, and nothing it writes
/// then is carried out (the calls are only counted). Returns whether the model was asked.
private func sumUpSource(_ call: ToolCall, forModel: JSONValue, after request: [ChatMessage], model: MLXChatModel,
                         into result: inout CaseResult) async throws -> Bool
{
    let called = request + [.call(call)]
    result.resultTokens = try await model.tokenCount(called + [.result(of: call, forModel)]) - model.tokenCount(called)
    let clock = ContinuousClock()
    let start = clock.now
    var text = ""
    var calls: [String] = []
    for try await output in model.reply(to: called + [.result(of: call, forModel)]) {
        switch output {
        case .text(let piece):
            if result.summaryFirstMs == nil, piece.contains(where: \.isLetter) {
                result.summaryFirstMs = milliseconds(clock.now - start)
            }
            text += piece
        case .toolCall(let made): calls.append(describe(made, written: nil))
        case .moreToolCalls: calls.append("another call, not written")
        case .unreadableToolCall(let raw): calls.append("unreadable: \(raw)")
        case .toolCallStarted, .toolCallNamed: break
        }
    }
    result.summaryMs = milliseconds(clock.now - start)
    var filter = ReasoningFilter()
    let summary = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
    result.summary = summary.isEmpty ? "(nothing: the app says its own sentence)" : summary
    result.callsWhileSumming = calls
    // The main number of the data ("47 minutes", "1,12 dollar", "15 degrés"): its digits must be in the summary.
    if case .object(let fields) = forModel {
        let main = ["duree", "cours", "temperature", "maximum"].compactMap { fields[$0]?.text }
            + (fields["previsions"].flatMap { value -> [String]? in
                guard case .array(let days) = value, case .object(let day)? = days.first else { return nil }
                return [day["maximum"]?.text].compactMap { $0 }
            } ?? [])
            + (fields["maintenant"].flatMap { value -> [String]? in
                guard case .object(let now) = value else { return nil }
                return [now["temperature"]?.text].compactMap { $0 }
            } ?? [])
        let said = summary.replacingOccurrences(of: "[\u{00A0}\u{202F} ]", with: "", options: .regularExpression)
        let numbers = main.compactMap { text -> String? in
            // A rate's number is the one after "vaut" ("1 euro vaut 1,12 dollar (taux d’hier…)").
            let value = text.components(separatedBy: " vaut ").last ?? text
            let plain = value.replacingOccurrences(of: "[\u{00A0}\u{202F} ]", with: "", options: .regularExpression)
            return plain.range(of: #"\d+(,\d+)?"#, options: .regularExpression).map { String(plain[$0]) }
        }
        result.keepsNumber = numbers.isEmpty ? nil : numbers.contains { said.contains($0) }
    }
    if call.name == QuoteCatalog.name {
        let folded = summary.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        result.saysWhen = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "aujourd'hui",
                           "aujourd’hui", "hier", "ce matin", "ce soir", "octobre", "novembre"].contains { folded.contains($0) }
            || folded.range(of: #"\d+ ?h"#, options: .regularExpression) != nil
    }
    return true
}

/// The app's check of a built-in source's call.
private func checkSource(_ call: ToolCall, context: ToolContext) throws {
    switch call.name {
    case WeatherCatalog.name: try WeatherCatalog.check(call, context: context)
    case QuoteCatalog.name: try QuoteCatalog.check(call, context: context)
    default: try TravelTimeCatalog.check(call, context: context)
    }
}

/// "EUR/USD", "bitcoin/EUR".
private func describe(_ instrument: Instrument) -> String {
    switch instrument {
    case .currency(let base, let quote): "\(base)/\(quote)"
    case .crypto(let id, _, let currency): "\(id)/\(currency)"
    }
}

/// Whether the app reads a source's call as the corpus expects: no place for "here", the forecast's day, the
/// instrument, the travel mode and the time to arrive by.
private func sourceMatches(_ call: ToolCall, _ expected: Corpus.Expected, _ context: ToolContext) -> Bool {
    switch call.name {
    case WeatherCatalog.name:
        if expected.here == true, WeatherCatalog.place(call) != nil { return false }
        guard let when = expected.when else { return true }
        let days: [Date]?
        do { days = try WeatherCatalog.days(call, context: context) } catch { return false }
        if when == "none" { return days == nil }
        guard let wanted = LocalDateTime.parse(when, in: context.timeZone)?.date, let days else { return false }
        return days.contains { context.calendar.isDate($0, inSameDayAs: wanted) }
    case QuoteCatalog.name:
        // A pair of currencies either way round: the model is given both rates.
        guard let wanted = expected.instrument else { return true }
        let found = QuoteCatalog.instrument(QuoteCatalog.words(call) ?? "")
        if case .currency(let base, let quote)? = found { return [base + "/" + quote, quote + "/" + base].contains(wanted) }
        // A crypto in either currency: the model is given both prices.
        if case .crypto(let id, _, _)? = found { return wanted.hasPrefix(id + "/") }
        return false
    default:
        if expected.here == true, TravelTimeCatalog.origin(call) != nil { return false }
        if let mode = expected.mode, TravelTimeCatalog.mode(call).rawValue != mode { return false }
        guard let when = expected.when else { return true }
        let arrive: Date?
        do { arrive = try TravelTimeCatalog.arriveBy(call, context: context) } catch { return false }
        if when == "none" { return arrive == nil }
        return arrive == LocalDateTime.parse(when, in: context.timeZone)?.date
    }
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
              reference == id || ActionCatalog.meansLastItem(reference)
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
    let text = folded(call.text("consigne") ?? call.text("message") ?? WebSearchCatalog.query(call)
        ?? WeatherCatalog.place(call) ?? QuoteCatalog.words(call) ?? TravelTimeCatalog.destination(call) ?? "")
    return mentions.allSatisfy { text.contains(folded($0)) }
}

/// Whether a memory call holds the expected words (in `texte`, `reference` or `quand`), whatever the accents and case;
/// `when`: the period's words expected in `quand`.
private func memoryMentions(_ call: ToolCall, _ expected: Corpus.Expected) -> Bool {
    let text = MemoryText.folded([call.text("texte"), call.text("reference"), call.text("quand"), call.text("fait"),
                                  call.text("requete")].compactMap { $0 }.joined(separator: " "))
    let mentions = (expected.mentions ?? []).allSatisfy { text.contains(MemoryText.folded($0)) }
    let when = expected.when.map { MemoryText.folded(call.text("quand") ?? "").contains(MemoryText.folded($0)) } ?? true
    return mentions && when
}

/// What the app would check of a memory call, without a store: the fact rests on the user's words; a period it can read;
/// an entry of the sheet to forget.
private func checkMemory(_ call: ToolCall, sheet: [String], context: ToolContext) throws {
    let refusal = { (why: String) in ToolRefusal(forModel: why, spoken: ActionPhrases.notUnderstood(.french)) }
    guard let action = MemoryCatalog.action(call) else { throw refusal("Il manque « action ».") }
    if let words = call.text("quand"), MemoryPeriod.read(words, now: context.now, calendar: context.calendar) == nil {
        throw refusal("« quand » (« \(words) ») : période illisible.")
    }
    let text = call.text("texte") ?? call.text("fait")
    switch action {
    case .retenir:
        guard let text else { throw refusal("Il manque « texte ».") }
        guard MemoryCatalog.wordsAreTheUser(text, said: context.userSaid) else {
            throw refusal("Ce texte ne reprend pas les mots de l'utilisateur.")
        }
    case .chercher:
        guard text != nil || call.text("quand") != nil else { throw refusal("Il manque « texte ».") }
    case .oublier:
        if call.text("quand") != nil, call.text("reference") == nil { return }
        guard let wanted = call.text("reference") ?? text, MemoryTools.entry(wanted, in: sheet) != nil else {
            throw refusal("Aucune entrée de la mémoire ne correspond.")
        }
    }
}

/// A search's words, whatever their order, accents and case.
private func keywords(_ query: String) -> Set<String> {
    Set(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        .split(whereSeparator: \.isWhitespace).map(String.init))
}

/// Whether the app refused a call as the corpus expects: for a date in the past ("past"), the one the words give (`when`):
/// the model's words, or the user's sentence when the model changed them (as the app reads them).
private func refusedAsExpected(_ call: ToolCall, _ refusal: ToolRefusal, _ expected: Corpus.Expected,
                               _ context: ToolContext) -> Bool
{
    if expected.refused == "weekday" {
        guard let when = expected.when, let wanted = LocalDateTime.parse(when, in: context.timeZone) else {
            return refusal.forModel.contains(" est un ")
        }
        return refusal.spoken == ActionPhrases.wrongWeekday(wanted.date, context)
    }
    guard expected.refused == "past", refusal.spoken == ActionPhrases.datePassed(context.language) else { return false }
    guard let when = expected.when else { return true }
    let raw = call.text("quand") ?? call.text("debut") ?? call.text("echeance") ?? ""
    let said = context.userSaid.first ?? ""
    let words = FrenchDates.wordsAreTheUser(raw, said: context.userSaid) || !FrenchDates.saysWhen(said) ? raw : said
    guard let moment = try? FrenchDates.moment(words, now: context.now, calendar: context.calendar),
          let wanted = LocalDateTime.parse(when, in: context.timeZone)
    else { return false }
    return wanted.hasTime ? moment.hasTime && moment.start == wanted.date
        : context.calendar.isDate(moment.start, inSameDayAs: wanted.date)
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
    // A request wrong at first and right at the second try; or right at first, its second try (after a refusal the
    // corpus expects) not wrong.
    let rightInApp = actions.filter {
        $0.toolOK && $0.argumentsOK != false ? $0.rightAfterSecondTry != false : $0.rightAfterSecondTry == true
    }.count
    print(String(format: "  with the app's second try after a refused call: %d / %d (%.0f %%)", rightInApp,
                 actions.count, percent(rightInApp, actions.count)))
    print("requests without an action that triggered one: \(falseTriggers.count) / \(others.count)"
          + falseTriggers.map { "\n    · \($0.phrase) → \($0.chosen)" }.joined())
    print("action requests answered without a tool: \(missed)")
    let more = results.filter { $0.moreCalls == true }
    print("requests with another call after the first (an action more than asked when one is expected): \(more.count)"
          + more.map { "\n    · \($0.phrase) → \($0.chosen) (expected: \($0.expected))" }.joined())
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
    if results.contains(where: { BuiltInSources.names.contains($0.expected) || BuiltInSources.names.contains($0.chosen) }) {
        summarizeSources(results)
    }

    // Expected / chosen.
    let optional = AgentCatalog.names.union([WebSearchCatalog.searchName]).union(BuiltInSources.names)
        .union([NewsCatalog.readName])
    let tools = ["creer_evenement", "creer_rappel", "lire_agenda", "lister_rappels", "modifier_element",
                 "supprimer_element", "minuteur", "lancer_raccourci", AgentCatalog.delegateName, AgentCatalog.statusName,
                 AgentCatalog.followUpName, AgentCatalog.cancelName, WebSearchCatalog.searchName, WeatherCatalog.name,
                 QuoteCatalog.name, TravelTimeCatalog.name, NewsCatalog.readName, "aucun"]
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
    let peaks = results.compactMap(\.peakGB)
    print(String(format: "GPU memory peak during a request: median %.2f GB, max %.2f GB", median(peaks) ?? 0,
                 peaks.max() ?? 0))

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
    func written(_ item: CaseResult) -> String {
        item.chosen == search ? WebSearchCatalog.query(ToolCall(name: search, arguments: item.arguments ?? [:])) ?? "" : ""
    }
    let afterSearch = results.filter { $0.earlierSearches != nil }
    if !afterSearch.isEmpty {
        let again = afterSearch.filter { $0.chosen == search }
        print("  after an earlier search: searched again \(again.count) / \(afterSearch.count) (expected "
              + "\(afterSearch.filter { $0.expected == search }.count)), with the same keywords as before "
              + "\(again.filter { $0.sameKeywordsAsBefore == true }.count)"
              + again.map { "\n    · \($0.phrase) → \(written($0))" }.joined())
    }
    let leavingOut = results.filter { written($0).lowercased().contains("-site:") }
    print("  keywords leaving a site out (-site:): \(leavingOut.count)"
          + leavingOut.map { "\n    · \($0.phrase) → \(written($0))" }.joined())
    let summed = results.filter { $0.chosen == search && $0.summary != nil }
    let calling = summed.filter { !($0.callsWhileSumming ?? []).isEmpty }
    print("  summaries: \(summed.count); with calls written while summing up (the app carries out none): \(calling.count)"
          + calling.map { "\n    · \($0.phrase) → \(($0.callsWhileSumming ?? []).joined(separator: "; "))" }.joined())
    let again = summed.filter { $0.summedUpAgain == true }
    print("  summed up once more after a call alone: \(again.count), still nothing said: "
          + "\(again.filter { $0.summary?.hasPrefix("(nothing") == true }.count)")
    let rated = summed.filter { $0.namesASite != nil }
    print("  summaries naming a site of the results: \(rated.filter { $0.namesASite == true }.count) / \(rated.count)")
    let calls = results.filter { $0.chosen == search }.compactMap(\.callMs)
    print("  time to a complete search call: median \(fmt(median(calls))), worst \(fmt(calls.max()))")
    let firstWords = summed.compactMap(\.summaryFirstMs)
    print("  results → first words of the summary: median \(fmt(median(firstWords))), worst \(fmt(firstWords.max()))")
    let tokens = summed.compactMap(\.resultTokens).map(Double.init)
    print("  the results in the model's memory: median \(median(tokens).map { String(Int($0)) } ?? "—") tokens, most "
          + "\(tokens.max().map { String(Int($0)) } ?? "—")")
    let searches = results.filter { $0.chosen == search }.compactMap(\.searchMs)
    if !searches.isEmpty {
        print("  the searches themselves (--searxng): median \(fmt(median(searches))), worst \(fmt(searches.max()))")
    }
}

/// The built-in sources' figures: the right decisions (to call one or not), by tool; the calls by mistake and the missed
/// ones; the calls the app reads as expected; and what the summaries did.
private func summarizeSources(_ results: [CaseResult]) {
    let names = BuiltInSources.names
    func phrases(_ items: [CaseResult]) -> String {
        items.map { "\n    · \($0.phrase) → \($0.chosen) (expected: \($0.expected))" }.joined()
    }
    let wanted = results.filter { names.contains($0.expected) }
    let others = results.filter { !names.contains($0.expected) }
    let mistaken = others.filter { names.contains($0.chosen) }
    let missed = wanted.filter { !$0.toolOK }
    let right = results.count - mistaken.count - missed.count
    print(String(format: "\nbuilt-in sources: right decisions (the right source, or none) %d / %d (%.0f %%)", right,
                 results.count, percent(right, results.count)))
    for name in [WeatherCatalog.name, QuoteCatalog.name, TravelTimeCatalog.name] {
        let these = wanted.filter { $0.expected == name }
        guard !these.isEmpty else { continue }
        let ok = these.filter(\.toolOK)
        print("  \(name): \(ok.count) / \(these.count) right tool, \(ok.filter { $0.argumentsOK != false }.count) read as "
              + "expected" + ok.filter { $0.argumentsOK == false }
                  .map { "\n    · \($0.phrase) → \(describe($0.arguments ?? [:]))" }.joined())
    }
    print("  sources called by mistake: \(mistaken.count) / \(others.count)" + phrases(mistaken))
    print("  missed: \(missed.count) / \(wanted.count)" + phrases(missed))
    let summed = results.filter { names.contains($0.chosen) && $0.summary != nil }
    let calling = summed.filter { !($0.callsWhileSumming ?? []).isEmpty }
    print("  summaries: \(summed.count); with calls written while summing up (the app carries out none): \(calling.count)"
          + calling.map { "\n    · \($0.phrase) → \(($0.callsWhileSumming ?? []).joined(separator: "; "))" }.joined())
    let rated = summed.filter { $0.keepsNumber != nil }
    print("  summaries keeping the data's main number as written: \(rated.filter { $0.keepsNumber == true }.count) / "
          + "\(rated.count)" + rated.filter { $0.keepsNumber == false }.map { "\n    · \($0.phrase) → “\($0.summary ?? "")”" }.joined())
    let quotes = summed.filter { $0.saysWhen != nil }
    print("  quotes saying when they are from: \(quotes.filter { $0.saysWhen == true }.count) / \(quotes.count)"
          + quotes.filter { $0.saysWhen == false }.map { "\n    · \($0.phrase) → “\($0.summary ?? "")”" }.joined())
    let long = summed.filter { ($0.summary ?? "").filter { ".!?".contains($0) }.count > 2 }
    print("  summaries of more than two sentences: \(long.count)" + long.map { "\n    · \($0.phrase)" }.joined())
    for name in [WeatherCatalog.name, QuoteCatalog.name, TravelTimeCatalog.name] {
        let these = results.filter { $0.chosen == name }
        guard !these.isEmpty else { continue }
        let calls = these.compactMap(\.callMs), asked = these.compactMap(\.searchMs)
        let firstWords = these.compactMap(\.summaryFirstMs), ends = these.compactMap(\.summaryMs)
        let tokens = these.compactMap(\.resultTokens).map(Double.init)
        print("  \(name): complete call median \(fmt(median(calls))); "
              + (asked.isEmpty ? "" : "the source itself median \(fmt(median(asked))), worst \(fmt(asked.max())); ")
              + "data → first words median \(fmt(median(firstWords))), worst \(fmt(firstWords.max())); "
              + "→ end of the summary median \(fmt(median(ends))); the data \(median(tokens).map { String(Int($0)) } ?? "—") tokens")
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

// MARK: - Several actions in one request

/// One call of a request with several actions, as the bench scores it.
private struct CallResult: Encodable {
    var expected: String
    var chosen: String
    var arguments: [String: JSONValue]?
    var toolOK: Bool
    var argumentsOK: Bool?
    var resolved: String?
    var refusal: String?
    var callMs: Double?
}

private struct SeveralResult: Encodable {
    var phrase: String
    /// The actions expected, in order.
    var expected: [String]
    var calls: [CallResult]
    /// The model went on to one more call than the app carries out in one request (`ModelOutput.moreToolCalls`).
    var moreCalls: Bool
    var unreadable: Int
    var text: String
    /// Every action right, in order, and nothing more (beyond the app's limit: the first ones, then `moreCalls`).
    var allRight: Bool
    /// Calls written beyond the ones expected.
    var extra: Int
    var firstCallMs: Double?
    var lastCallMs: Double?
}

/// A corpus whose requests ask for several actions at once (`expected` written as a list): every call the model writes is
/// scored, in order, against the action expected at its place (the tool its name stands for, and what the app would make
/// of it: the date to the minute, the length, the shortcut, the words of a task or a search), as `runActionsBench` scores
/// one. A call more than expected counts as an extra action. A change or a deletion of « le dernier » refers to the item
/// created by the call before it in the same request. Nothing is carried out, and no second pass is asked for (no
/// second try, no summary). With `maxCalls` lower than the actions asked for, the request is right when the first ones are
/// and the model went on to another call (the app then says how many it does at a time).
private func runSeveralActions(_ corpus: Corpus, conversation: Conversation, tools: [ToolSpec], dateLine: String,
                               now: Date, timeZone: TimeZone, model: MLXChatModel, maxCalls: Int, tier: HardwareTier,
                               modelName: String, options o: Options) async throws
{
    let reference = ToolContext(now: now, timeZone: timeZone, language: .french)
    func named(_ call: ToolCall) -> ToolCall {
        var named = call
        named.name = ToolNames.match(call.name, among: tools.map(\.name)) ?? call.name
        return named
    }
    let clock = ContinuousClock()
    var results: [SeveralResult] = []
    for (index, item) in corpus.cases.enumerated() {
        let expected = item.expectedList ?? item.expected.map { [$0] } ?? []
        let request = caseRequest(item, in: conversation, corpus: corpus, dateLine: dateLine, context: reference)
        var written: [(call: ToolCall, ms: Double)] = []
        var text = ""
        var moreCalls = false
        var unreadable = 0
        let start = clock.now
        for try await output in model.reply(to: request) {
            switch output {
            case .text(let piece): text += piece
            case .toolCall(let call): written.append((call, milliseconds(clock.now - start)))
            case .moreToolCalls: moreCalls = true
            case .unreadableToolCall: unreadable += 1
            case .toolCallStarted, .toolCallNamed: break
            }
        }
        var filter = ReasoningFilter()
        text = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)
        // As the app: for a request with several calls, only each call's own words (`VoicePipeline.answerWithTools`).
        let several = written.count > 1 || moreCalls
        let context = ToolContext(now: now, timeZone: timeZone, language: .french,
                                  userSaid: several ? [] : [item.phrase] + corpus.exchanges(before: item).reversed().map(\.user))
        var calls: [CallResult] = []
        /// The item the calls before created, for a change of « le dernier » after it (or the case's earlier exchange).
        var created = corpus.exchanges(before: item).last
        for (place, entry) in written.enumerated() {
            let call = named(entry.call)
            let wanted = place < expected.count ? expected[place] : nil
            var result = CallResult(expected: wanted?.tool ?? "aucun", chosen: call.name, arguments: call.arguments,
                                    toolOK: call.name == wanted?.tool, callMs: entry.ms)
            if AgentCatalog.names.contains(call.name) {
                do {
                    try AgentCatalog.check(call, context: context, agents: [ClaudeCode.displayName], folders: [])
                    if result.toolOK, let wanted { result.argumentsOK = mentions(call, wanted) }
                } catch let refused as ToolRefusal {
                    result.refusal = refused.forModel
                    if result.toolOK { result.argumentsOK = false }
                }
            } else if call.name == WebSearchCatalog.searchName {
                do {
                    try WebSearchCatalog.check(call, context: context)
                    if result.toolOK, let wanted { result.argumentsOK = mentions(call, wanted) }
                } catch let refused as ToolRefusal {
                    result.refusal = refused.forModel
                    if result.toolOK { result.argumentsOK = false }
                }
            } else {
                do {
                    let resolved = try resolve(call, created: created, context: context, shortcuts: corpus.shortcuts)
                    result.resolved = resolved.description(timeZone)
                    if result.toolOK, let wanted { result.argumentsOK = wanted.refused == nil && matches(resolved, wanted, context) }
                    if [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name].contains(call.name) {
                        created = createdExchange(call, resolved, number: place + 1, timeZone: timeZone)
                    }
                } catch let refused as ToolRefusal {
                    result.refusal = refused.forModel
                    if result.toolOK, let wanted { result.argumentsOK = refusedAsExpected(call, refused, wanted, context) }
                }
            }
            calls.append(result)
        }
        let carriedOut = min(expected.count, maxCalls)
        let rightCalls = calls.prefix(carriedOut).filter { $0.toolOK && $0.argumentsOK != false }.count
        let extra = max(0, calls.count - expected.count)
        let allRight = calls.count == carriedOut && rightCalls == carriedOut && (expected.count > maxCalls) == moreCalls
        let result = SeveralResult(phrase: item.phrase, expected: expected.map(\.tool), calls: calls, moreCalls: moreCalls,
                                   unreadable: unreadable, text: text, allRight: allRight, extra: extra,
                                   firstCallMs: written.first?.ms, lastCallMs: written.last?.ms)
        results.append(result)
        print(String(format: "%3d %@ %@", index + 1, allRight ? "✓" : "✗", item.phrase))
        for (place, call) in calls.enumerated() {
            let mark = call.toolOK ? (call.argumentsOK == false ? "~" : "✓") : "✗"
            print("      \(mark) \(describe(written[place].call, written: nil))" + (call.resolved.map { " = \($0)" } ?? "")
                  + (call.refusal.map { "  [refused: \($0)]" } ?? "") + "  \(fmt(call.callMs))"
                  + (call.toolOK ? "" : "  (expected: \(call.expected))"))
        }
        if calls.count < expected.count {
            print("      missing: \(expected[calls.count...].map(\.tool).joined(separator: ", "))"
                  + (moreCalls ? "  [then another call, not written]" : ""))
        } else if moreCalls {
            print("      [then another call, not written]")
        }
        if unreadable > 0 { print("      unreadable calls: \(unreadable)") }
        if !text.isEmpty { print("      said: “\(text.prefix(120))”") }
    }

    print("\n=== \(modelName) — \(results.count) requests, at most \(maxCalls) action(s) carried out per request ===")
    let several = results.filter { $0.expected.count > 1 }
    let rightSeveral = several.filter(\.allRight).count
    print(String(format: "requests with several actions, every action right: %d / %d (%.0f %%)", rightSeveral,
                 several.count, percent(rightSeveral, several.count)))
    for count in Set(several.map(\.expected.count)).sorted() {
        let group = several.filter { $0.expected.count == count }
        print("  \(count) actions: \(group.filter(\.allRight).count) / \(group.count)")
    }
    let single = results.filter { $0.expected.count == 1 }
    if !single.isEmpty {
        print("requests with one action (sounding like two): right \(single.filter(\.allRight).count) / \(single.count), "
              + "extra actions \(single.map(\.extra).reduce(0, +))"
              + single.filter { $0.extra > 0 }.map { "\n    · \($0.phrase) → \($0.calls.map(\.chosen).joined(separator: ", "))" }
                  .joined())
    }
    let allCalls = results.flatMap(\.calls)
    print("calls written: \(allCalls.count) · right tool \(allCalls.filter(\.toolOK).count) · right tool and arguments "
          + "\(allCalls.filter { $0.toolOK && $0.argumentsOK != false }.count) · beyond the actions expected "
          + "\(results.map(\.extra).reduce(0, +)) · unreadable \(results.map(\.unreadable).reduce(0, +))")
    let short = several.filter { $0.calls.count < min($0.expected.count, maxCalls) }
    print("requests with fewer calls than asked for: \(short.count)"
          + short.map { "\n    · \($0.phrase) → \($0.calls.map(\.chosen).joined(separator: ", "))" }.joined())
    let shortPhrases = Set(short.map(\.phrase))
    let wrong = several.filter { !$0.allRight && !shortPhrases.contains($0.phrase) }
    print("other requests with several actions not all right: \(wrong.count)"
          + wrong.map { "\n    · \($0.phrase)" }.joined())
    let firsts = several.compactMap(\.firstCallMs)
    let lasts = several.filter { $0.calls.count > 1 }.compactMap(\.lastCallMs)
    print("first call complete: median \(fmt(median(firsts))) · last call complete (with several): median "
          + "\(fmt(median(lasts))), worst \(fmt(lasts.max()))")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("actions-bench-several-\(tier.rawValue)-max\(maxCalls)-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(results).write(to: url)
    print("report: \(url.path)")
}

/// An item created by a call of the request, as the app describes it to the model: what a change of « le dernier » after it
/// in the same request starts from.
private func createdExchange(_ call: ToolCall, _ resolved: Resolved, number: Int, timeZone: TimeZone) -> Corpus.Exchange {
    let event = call.name == ActionCatalog.createEvent.name
    var fields: [String: JSONValue] = ["id": .string((event ? "e" : "r") + String(number))]
    if let start = resolved.start {
        fields[event ? "debut" : "echeance"] = .string(LocalDateTime.format(start, in: timeZone, withTime: resolved.hasTime))
    }
    if event, let end = resolved.end {
        fields["fin"] = .string(LocalDateTime.format(end, in: timeZone, withTime: resolved.hasTime))
    }
    return Corpus.Exchange(user: "", call: call, result: .object(fields), found: nil, answer: "", dateLine: nil)
}
