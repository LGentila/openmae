// voice-cli journal-bench — with the memory's journal switched on, does the model search it when the user asks about a
// past conversation, does the search find the exchange, and does the answer use it?
//
//   voice-cli journal-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                           [--corpus Tests/Fixtures/journal-fr.json] [--repeats 3] [--examples app|none|file]
//                           [--web] [--request "cookies"] [--watch-calls] [--own-thoughts] [--out measurements]
//                           [--embedder folder [--fusion fts1-meaning@0.2] [--meaning-of keywords|request|both]]
//                           [--widen-words] [--replay report.json [--widen-model]]
//
// The study of issue #167. --embedder: the journal searched by meaning too, with this sentence-embedding model's folder
// (`MeaningJournal`): --fusion, how its ranking and the full-text search's are put together (`MeaningFusion`, with a
// cosine floor after « @ »); --meaning-of, what it embeds: the model's keywords, the user's request, or the better of
// the two. --widen-words: the keywords widened with the system's French word embedding. --replay: no language model
// runs; the searches an earlier report holds (the keywords and periods the model wrote) are searched again in each way
// of the study, and the report counts how often the expected exchange is among the excerpts; --widen-model asks the
// tier's model, in a short pass of its own, for the words the exchange may have used, and times that pass.
//
// --request: only the corpus's requests whose phrase holds this text (repeatable), to run a rare case many times.
// --watch-calls: each pass exactly as the model wrote it, special tokens included, under its run; the report keeps it with
// its tokens, each with its chance and the likeliest ones there, and counts the passes that open a thought block of the
// model's own or hold « much ».
// --own-thoughts: Gemma 4 26B may write thought blocks of its own in its answers, as before it was kept from it
// (`MLXChatModel.allowOwnThoughts`), to compare in one build.
//
// Text only, and nothing is carried out for real. The journal is switched on for this run only, on any tier, whatever
// the app's settings say and whether the app offers it on that tier (`MemorySettings.journalOffered(on:)`, which the
// report's first lines say): the app's store (`SQLiteMemoryStore`) in a folder of the system's temporary directory,
// deleted at the end, never the user's. It holds the exchanges of the corpus's "journal"
// (Tests/Fixtures/memory-fr.json, memory-bench's) and the corpus's own, where Maé gave something (a recipe, an address,
// a recommendation…); the sheet in the prompt is the corpus's. Each request starts a new conversation, as the app has
// it with the actions on, the memory's tool with the journal (`memoire`: retenir, chercher, oublier) last, and with
// "web": true (or --web) the web search, which searches nothing (a call is declined). Each call goes through the app's
// `ToolRunner`, its checks and its second try; a search through the app's `MemoryTools`, whose excerpts the model then
// sums up as in the app (`AppTalk`, dialogue-bench's turn). The model samples its answers: each request runs --repeats
// times (default 3). A fact remembered on the way is taken out of the sheet before the next request.
//
// The report, per kind of request — what the user said or what Maé said; with a period or without; with some of the
// exchange's own words or with other words — counts the runs where the model searched the journal (a `chercher` call),
// where the expected exchange was among the excerpts the tool gave it ("found"), and where the answer then used it (it
// says one of the request's `answerMentions`, words of that exchange: "used"), with what the model did instead of
// searching and the periods it wrote (`quand`). For the requests that must not search (a new question on a topic the
// journal holds, a fact to remember, a general question), the runs that searched anyway. Then each request on its own,
// with the keywords the model wrote. When a search missed the exchange, the report also counts the answers that say so
// (by their words, roughly) rather than tell something else. The corpus is checked first: a request "with other words"
// that shares a search term with its exchange, or "with the same words" that shares none, is reported.

import Foundation
import VoiceCore
import VoiceEngineApple

private struct JournalCorpus: Decodable {
    var now: String
    /// A corpus of memory-bench (its exchanges, not its queries), the journal's first part.
    var journal: String?
    /// The web search switched on too (as with --web).
    var web: Bool?
    var sheet: [String]?
    var exchanges: [Exchange]
    var requests: [Request]

    struct Exchange: Decodable {
        var id: String
        var date: String
        var user: String
        var answer: String
        var language: String?
        /// "external": the answer used something from outside (a web search, an agent).
        var source: String?
    }

    struct Request: Decodable {
        var phrase: String
        /// "user": about what the user said; "mae": about what Maé said.
        var about: String?
        /// "same": some of the exchange's own words; "other": none of them.
        var words: String?
        /// The period said, in the words `quand` should carry.
        var period: String?
        var expected: [String]?
        var answerMentions: [String]?
        /// A request that must not search: "new", "remember", "general".
        var kind: String?

        var mustSearch: Bool { kind == nil }

        /// "what Maé said · other words · with a period".
        var label: String {
            if let kind { return Self.kinds[kind] ?? kind }
            return (about == "mae" ? "what Maé said" : "what the user said")
                + (words == "other" ? " · other words" : " · same words")
                + (period == nil ? "" : " · with a period")
        }

        static let kinds = ["new": "a new question", "remember": "a fact to remember", "general": "a general question"]
    }
}

/// memory-bench's corpus, for its exchanges.
private struct BaseJournal: Decodable {
    var exchanges: [JournalCorpus.Exchange]
}

/// One run of one request.
private struct JournalRun: Encodable {
    var phrase: String
    var label: String
    var run: Int
    /// What the model did first: "memoire chercher", "chercher_web", "memoire retenir", "no call"…
    var first: String
    /// The searches it wrote (at any pass): their keywords and period, and whether the app refused them.
    var searches: [Search]
    /// The exchanges the searches gave the model, by the corpus's ids, in order.
    var excerpts: [String]
    var searched: Bool
    var found: Bool?
    var used: Bool?
    /// What the user heard.
    var answer: String
    var seconds: Double
    /// The model's first answer wrote neither a word nor a call: it was asked once more, as the app does.
    var askedAgain: Bool?
    /// With --watch-calls: each pass of the model as it wrote it, and its tokens.
    var raw: [String]?
    var tokens: [[WatchedToken]]?

    struct Search: Encodable {
        var texte: String?
        var quand: String?
        var refused: Bool
        /// The period the app read from `quand` holds the expected exchange.
        var periodHoldsIt: Bool?
    }
}

/// The app's store, keeping what each search gave the model (the exchanges' ids), for the report. It never deletes
/// anything: the journal stays as the corpus has it.
private actor RecordingStore: MemoryStore {
    private let store: any MemoryStore
    private(set) var found: [Int64] = []

    init(_ store: any MemoryStore) {
        self.store = store
    }

    func forget() { found = [] }

    func loadSheet() async throws -> [String] { try await store.loadSheet() }
    func saveSheet(_ entries: [String]) async throws { try await store.saveSheet(entries) }
    func addExchange(_ entry: JournalEntry) async throws -> Int64 { try await store.addExchange(entry) }
    func searchJournal(_ query: JournalQuery) async throws -> [JournalHit] {
        let hits = try await store.searchJournal(query)
        found += hits.compactMap(\.entry.id)
        return hits
    }
    func countJournal(from: Date?, to: Date?) async throws -> Int { try await store.countJournal(from: from, to: to) }
    func deleteJournal(from: Date?, to: Date?) async throws -> Int { 0 }
    func deleteJournal(ids: [Int64]) async throws -> Int { 0 }
}

/// The web search switched on, as the model sees it. Nothing is searched: a call is declined.
private struct UnsearchedWeb: ToolProvider {
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

func runJournalBench(_ o: Options) async throws {
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/journal-fr.json")
    let corpus = try JSONDecoder().decode(JournalCorpus.self, from: Data(contentsOf: corpusURL))
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? corpus.now, in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }
    let reference = ToolContext(now: now, timeZone: timeZone, language: .french)

    // 1. The journal, in date order: the base corpus's exchanges and the corpus's own.
    var exchanges = corpus.exchanges
    if let base = corpus.journal {
        exchanges += try JSONDecoder().decode(BaseJournal.self, from: Data(contentsOf: URL(fileURLWithPath: base))).exchanges
    }
    var dateOf: [String: Date] = [:]
    for exchange in exchanges {
        guard let date = LocalDateTime.parse(exchange.date, in: timeZone)?.date else {
            throw CLIError("\(exchange.id): unreadable date \(exchange.date)")
        }
        dateOf[exchange.id] = date
    }
    exchanges.sort { dateOf[$0.id]! < dateOf[$1.id]! }
    let byID = Dictionary(exchanges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for request in corpus.requests {
        for id in request.expected ?? [] where byID[id] == nil { throw CLIError("« \(request.phrase) »: no exchange \(id)") }
        if request.mustSearch, (request.expected ?? []).isEmpty || (request.answerMentions ?? []).isEmpty {
            throw CLIError("« \(request.phrase) »: a search request needs expected and answerMentions")
        }
    }
    checkWords(corpus.requests, byID: byID)
    let requests = o.requests.isEmpty ? corpus.requests
        : corpus.requests.filter { request in o.requests.contains { request.phrase.contains($0) } }
    guard !requests.isEmpty else { throw CLIError("--request: no request of the corpus holds these words") }

    let scratch = FileManager.default.temporaryDirectory.appending(path: "openmae-journal-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    // The study of issue #167: the journal searched by meaning too (--embedder), or its keywords widened (--widen-words).
    var meaning: MeaningJournal?
    if o.embedder != nil || o.widenWords || o.replay != nil {
        var embedder: SentenceEmbedder?
        if let path = o.embedder {
            embedder = try await SentenceEmbedder.load(directory: URL(fileURLWithPath: path), cpu: o.embedderCPU)
        }
        let (fusion, floor) = studyFusion(o.fusion ?? (embedder == nil ? "fts" : "rrf"))
        meaning = MeaningJournal(store: try SQLiteMemoryStore(folder: scratch), embedder: embedder, fusion: fusion,
                                 meaningOf: o.meaningOf ?? "keywords", widen: o.widenWords)
        await meaning?.setFusion(fusion, cosineFloor: floor)
        print("searching: \(fusion.rawValue)" + (floor > 0 ? " (cosine at least \(floor))" : "")
              + (embedder.map { " · by meaning with \($0.folder.lastPathComponent), reading \(o.meaningOf ?? "keywords")" } ?? "")
              + (o.widenWords ? " · keywords widened" : ""))
    }
    let inner: any MemoryStore
    if let meaning { inner = meaning } else { inner = try SQLiteMemoryStore(folder: scratch) }
    let store = RecordingStore(inner)
    var corpusID: [Int64: String] = [:]
    for exchange in exchanges {
        let id = try await store.addExchange(JournalEntry(
            date: dateOf[exchange.id]!, user: exchange.user, answer: exchange.answer,
            language: exchange.language == "en" ? .english : .french,
            source: exchange.source == "external" ? .external : .normal))
        corpusID[id] = exchange.id
    }
    let sheet = corpus.sheet ?? []
    try await store.saveSheet(sheet)
    if let replay = o.replay, let meaning {
        var widener: MLXChatModel?
        if o.widenModel {
            let tier = try tierOption(o)
            let models = ModelStore()
            guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
            widener = try await MLXChatModel.load(directory: o.llm.map { URL(fileURLWithPath: $0) } ?? models.folder(pack))
        }
        try await replaySearches(replay, journal: meaning, corpus: corpus, corpusID: corpusID, dateOf: dateOf,
                                 now: now, calendar: reference.calendar, widener: widener)
        return
    }

    // 2. The model, with the app's tools: the actions, the web search, the memory with its journal (last).
    let tier = try tierOption(o)
    let models = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? models.folder(pack)
    guard o.llm != nil || models.isComplete([pack]) else {
        throw CLIError("\(pack.displayName) is not on this Mac: run “voice-cli download --tier \(tier.rawValue)” first")
    }
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue)) · reference time "
          + LocalDateTime.format(now, in: timeZone))
    print("journal: \(exchanges.count) exchanges (switched on for this run only, in a temporary folder; the app "
          + (MemorySettings.journalOffered(on: tier) ? "offers it" : "does not offer it") + " on this tier) · sheet: "
          + "\(sheet.count) entries · \(requests.count) requests"
          + (requests.count < corpus.requests.count ? " of \(corpus.requests.count)" : ""))
    let clock = ContinuousClock()
    let loadStart = clock.now
    let model = try await MLXChatModel.load(directory: folder)
    print("loaded in \(clock.now - loadStart)")
    if o.watchCalls {
        await model.watchToolCalls(true)
        await model.watchTokens(true)
    }
    await model.allowOwnThoughts(o.ownThoughts)
    if o.ownThoughts { print("thought blocks of the model's own allowed in its answers (--own-thoughts)") }
    let web = corpus.web == true || o.web
    let calendar = MemoryCalendar(movingItems: ActionCatalog.movesItems(on: tier))
    let memory = MemoryTools(store: store, enabled: true, journal: true)
    let providers: [any ToolProvider] = [calendar, TimerTools()] + (web ? [UnsearchedWeb()] : []) + [memory]
    let runner = ToolRunner(providers: providers)
    let tools = await runner.tools()
    await model.useTools(tools)
    let maxCalls = max(1, o.maxCalls ?? ActionCatalog.actionsPerRequest(on: tier))
    await model.limitToolCalls(maxCalls)
    var base = Conversation()
    let exampleCall = await model.toolCallText(ActionCatalog.example.call)
    base.systemAddenda = [ActionCatalog.promptAddendum(exampleCall: exampleCall)] + (await runner.promptAddenda())
    let examples = o.examples ?? (ActionCatalog.showsExamples(on: tier) ? "app" : "none")
    base.examples = try exampleExchanges(examples, now: now, timeZone: timeZone)
    try await model.prefillBeginning(base.beginning)
    let promptTokens = try await model.tokenCount(base.messages)
    print("tools: \(tools.map(\.name).joined(separator: ", ")) · \(maxCalls) calls at most per request · example "
          + "exchanges: \(examples) · system prompt \(promptTokens) tokens")
    let memoryTool = tools.first(where: { $0.name == MemoryCatalog.name })
    print("memoire: \(memoryTool?.description ?? "not offered")\n")

    // 3. Each request, a new conversation each time.
    let repeats = max(o.repeats ?? 3, 1)
    var runs: [JournalRun] = []
    let benchStart = clock.now
    for (index, request) in requests.enumerated() {
        print("\(index + 1) [\(request.label)] \(request.phrase)")
        let expected = Set(request.expected ?? [])
        for run in 1...repeats {
            await store.forget()
            await meaning?.setRequest(request.phrase)
            var talk = AppTalk(model: model, runner: runner, calendar: calendar, conversation: base, now: now,
                               timeZone: timeZone, maxCalls: maxCalls, watchCalls: o.watchCalls)
            let start = clock.now
            let (steps, answer, askedAgain) = try await talk.turn(request.phrase)
            let seconds = Double((clock.now - start).components.seconds)
                + Double((clock.now - start).components.attoseconds) / 1e18
            let calls = steps.compactMap { step in step.call.map { (call: $0, refused: step.refused) } }
            let searches = calls.filter { $0.call.name == MemoryCatalog.name && MemoryCatalog.action($0.call) == .chercher }
                .map { made -> JournalRun.Search in
                    let quand = made.call.text("quand")
                    var search = JournalRun.Search(texte: made.call.text("texte") ?? made.call.text("requete"),
                                                   quand: quand, refused: made.refused)
                    if let quand, !expected.isEmpty {
                        let period = MemoryPeriod.read(quand, now: now, calendar: reference.calendar)
                        search.periodHoldsIt = period.map { period in
                            expected.contains { dateOf[$0].map { $0 >= period.start && $0 < period.end } ?? false }
                        } ?? false
                    }
                    return search
                }
            let excerpts = await store.found.compactMap { corpusID[$0] }
            var result = JournalRun(phrase: request.phrase, label: request.label, run: run,
                                    first: calls.first.map { describeChoice($0.call) } ?? "no call", searches: searches,
                                    excerpts: excerpts, searched: !searches.isEmpty, answer: answer, seconds: seconds)
            if askedAgain { result.askedAgain = true }
            if o.watchCalls {
                let passes = steps.filter { $0.raw != nil }
                result.raw = passes.compactMap(\.raw)
                result.tokens = passes.map { $0.tokens ?? [] }
            }
            if request.mustSearch {
                let found = excerpts.contains(where: expected.contains)
                result.found = found
                result.used = found && says(answer, any: request.answerMentions ?? [])
            }
            runs.append(result)
            let marks = request.mustSearch
                ? [result.searched, result.found == true, result.used == true].map { $0 ? "✓" : "✗" }.joined()
                : (result.searched ? "✗ searched" : "✓")
            let wrote = searches.isEmpty ? result.first
                : searches.map { "chercher {texte: \($0.texte ?? "—")" + ($0.quand.map { ", quand: \($0)" } ?? "") + "}"
                    + ($0.refused ? " [refused]" : "") }.joined(separator: " then ")
            print("   \(run)/\(repeats) \(marks)  \(wrote)" + (excerpts.isEmpty ? "" : " → \(excerpts.joined(separator: ", "))")
                  + String(format: "  (%.1f s)", seconds)
                  + (askedAgain ? "  [the first answer said nothing: asked again]" : ""))
            print("        🔊 \(answer.prefix(220))")
            for (pass, raw) in (result.raw ?? []).enumerated() { print("        pass \(pass + 1): \(raw.debugDescription)") }

            // Back to the corpus's sheet (a fact remembered on the way is taken out), and to a new conversation.
            if try await store.loadSheet() != sheet { try await store.saveSheet(sheet) }
            await runner.resetConversation()
            try await model.prefillBeginning(base.beginning)
        }
    }
    print("\n\(runs.count) runs in \(clock.now - benchStart)")
    if let meaning {
        let writes = await meaning.writeMilliseconds.sorted(), searches = await meaning.searchMilliseconds.sorted()
        let embeds = await meaning.embedMilliseconds.sorted()
        func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a[a.count / 2] }
        print(String(format: "study: an exchange written %.1f ms (median) · a search %.1f ms (median, %d searches; "
                     + "embedding its words %.1f ms)", median(writes), median(searches), searches.count, median(embeds)))
    }
    summarize(runs, requests: requests, repeats: repeats, tier: tier, model: folder.lastPathComponent)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let report = o.out.appending(path: "journal-bench-\(tier.rawValue)-\(Int(Date().timeIntervalSince1970)).json")
    try encoder.encode(runs).write(to: report)
    print("report: \(report.path)")
}

/// "memoire chercher", "chercher_web", "memoire retenir".
private func describeChoice(_ call: ToolCall) -> String {
    call.name == MemoryCatalog.name ? "memoire \(MemoryCatalog.action(call)?.rawValue ?? "?")" : call.name
}

/// Whether the text says one of these words, at the start of a word, whatever the accents and case ("bavard" in
/// "bavarde", "2,4" in "2,4 bars").
private func says(_ text: String, any words: [String]) -> Bool {
    let said = " " + MemoryText.folded(text) + " "
    return words.contains { said.contains(" " + MemoryText.folded($0)) }
}

/// Whether an answer says it does not find, or know, what was asked, by its words (« je ne retrouve pas », « je n'ai
/// pas »…): a rough sign that it did not tell something else instead.
private func saysNotFound(_ text: String) -> Bool {
    let folded = text.lowercased().replacingOccurrences(of: "’", with: "'")
        .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    let phrases = ["trouve pas", "retrouve pas", "trouve rien", "retrouve rien", "ne sais pas", "pas d'information",
                   "ne me souviens pas", "pas de trace", "plus de details", "n'ai pas", "aucun", "pas cette information",
                   "ne vois pas", "je ne garde pas", "pas l'historique", "rappeler de quel", "peux-tu me rappeler",
                   "pas trouve", "rien trouve", "n'ai rien", "n'arrive pas"]
    return phrases.contains { folded.contains($0) }
}

/// The corpus's own check: the search terms a request's words give (its period's words aside), and whether its expected
/// exchanges hold one of them, as the search would read them (as a prefix of one of their words).
private func checkWords(_ requests: [JournalCorpus.Request], byID: [String: JournalCorpus.Exchange]) {
    var warnings: [String] = []
    for request in requests where request.mustSearch {
        var phrase = MemoryText.folded(request.phrase)
        if let period = request.period { phrase = phrase.replacingOccurrences(of: MemoryText.folded(period), with: " ") }
        let terms = JournalSearch.terms(phrase)
        for id in request.expected ?? [] {
            guard let exchange = byID[id] else { continue }
            let words = JournalSearch.indexed(exchange.user + " " + exchange.answer).split(separator: " ")
            let shared = terms.filter { term in words.contains { $0.hasPrefix(term) } }
            if request.words == "other", !shared.isEmpty {
                warnings.append("« \(request.phrase) » (other words) shares \(shared.joined(separator: ", ")) with \(id)")
            }
            if request.words == "same", shared.isEmpty {
                warnings.append("« \(request.phrase) » (same words) shares no search term with \(id)")
            }
        }
    }
    print(warnings.isEmpty ? "corpus: each request's words are as its kind says"
          : "corpus warnings:\n" + warnings.map { "  ⚠️  \($0)" }.joined(separator: "\n"))
}

private func summarize(_ runs: [JournalRun], requests: [JournalCorpus.Request], repeats: Int, tier: HardwareTier,
                       model: String)
{
    func share(_ part: Int, _ whole: Int) -> String {
        String(format: "%3d/%-3d %3.0f %%", part, whole, whole == 0 ? 0 : Double(part) * 100 / Double(whole))
    }
    /// "no call 5, chercher_web 2": the most frequent first.
    func counts(_ values: [String]) -> String {
        var tally: [String: Int] = [:]
        for value in values { tally[value, default: 0] += 1 }
        return tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
    func line(_ name: String, _ some: [JournalRun]) -> String {
        let searched = some.filter(\.searched)
        let instead = some.filter { !$0.searched }.map(\.first)
        let periods = searched.flatMap(\.searches).compactMap(\.quand)
        return name.padding(toLength: 46, withPad: " ", startingAt: 0)
            + " searched " + share(searched.count, some.count)
            + " · found " + share(some.filter { $0.found == true }.count, some.count)
            + " · used " + share(some.filter { $0.used == true }.count, some.count)
            + (instead.isEmpty ? "" : "\n" + String(repeating: " ", count: 48) + "instead: " + counts(instead))
            + (periods.isEmpty ? "" : "\n" + String(repeating: " ", count: 48) + "quand: " + counts(periods))
    }
    print("\n=== \(model) (tier \(tier.rawValue)): requests about a past conversation, \(repeats) runs each ===")
    let searching = runs.filter { run in requests.first { $0.phrase == run.phrase }?.mustSearch == true }
    for about in ["what the user said", "what Maé said"] {
        for words in ["same words", "other words"] {
            for period in [false, true] {
                let label = about + " · " + words + (period ? " · with a period" : "")
                let some = searching.filter { $0.label == label }
                if !some.isEmpty { print(line(label, some)) }
            }
        }
    }
    print("--- by one side of the request")
    print(line("what the user said", searching.filter { $0.label.hasPrefix("what the user said") }))
    print(line("what Maé said", searching.filter { $0.label.hasPrefix("what Maé said") }))
    print(line("same words", searching.filter { $0.label.contains("same words") }))
    print(line("other words", searching.filter { $0.label.contains("other words") }))
    print(line("without a period", searching.filter { !$0.label.contains("with a period") }))
    print(line("with a period", searching.filter { $0.label.contains("with a period") }))
    print(line("all", searching))
    let withPeriod = searching.filter { $0.label.contains("with a period") }.flatMap(\.searches)
    let withoutPeriod = searching.filter { !$0.label.contains("with a period") }.flatMap(\.searches)
    print("periods: searches with quand when a period was said \(withPeriod.filter { $0.quand != nil }.count)/"
          + "\(withPeriod.count), the period read holds the exchange \(withPeriod.filter { $0.periodHoldsIt == true }.count)"
          + "/\(withPeriod.filter { $0.quand != nil }.count); searches with quand when none was said "
          + "\(withoutPeriod.filter { $0.quand != nil }.count)/\(withoutPeriod.count); searches refused "
          + "\((withPeriod + withoutPeriod).filter(\.refused).count)")

    let missed = searching.filter { $0.searched && $0.found != true }
    let unsearched = searching.filter { !$0.searched }
    print("when the search missed the exchange, answers that say they do not find it "
          + "\(missed.filter { saysNotFound($0.answer) }.count)/\(missed.count) (the others tell something else); "
          + "without a search, answers that say they do not know \(unsearched.filter { saysNotFound($0.answer) }.count)"
          + "/\(unsearched.count)")

    print("\n=== requests that must not search, \(repeats) runs each ===")
    for kind in ["new", "remember", "general"] {
        let label = JournalCorpus.Request.kinds[kind] ?? kind
        let some = runs.filter { $0.label == label }
        guard !some.isEmpty else { continue }
        print(label.padding(toLength: 22, withPad: " ", startingAt: 0) + " searched the journal "
              + share(some.filter(\.searched).count, some.count) + " · what it did: " + counts(some.map(\.first)))
    }

    print("\n=== each request ===")
    for request in requests {
        let some = runs.filter { $0.phrase == request.phrase }
        let keywords = some.flatMap(\.searches).map { ($0.texte ?? "—") + ($0.quand.map { " | \($0)" } ?? "") }
        let numbers = request.mustSearch
            ? "searched \(some.filter(\.searched).count) found \(some.filter { $0.found == true }.count) used "
                + "\(some.filter { $0.used == true }.count) /\(some.count)"
            : "searched \(some.filter(\.searched).count)/\(some.count)"
        print("\(numbers)  \(request.phrase)" + (keywords.isEmpty ? "" : "\n      keywords: " + counts(keywords)))
    }

    // What the user would hear of the answers themselves: nothing at all, or « much », the word Gemma 4 26B writes for one
    // of its marks (`ReasoningFilter`; the corpus is French). And the first answers that said nothing, asked again.
    print("\n=== what is heard, all requests ===")
    print("nothing heard " + share(runs.filter { SpeakableText.clean($0.answer).isEmpty }.count, runs.count)
          + " · « much » heard " + share(runs.filter { $0.answer.lowercased().contains("much") }.count, runs.count)
          + " · first answer with nothing said, asked again " + share(runs.filter { $0.askedAgain == true }.count, runs.count))
    // With --watch-calls, the passes as the model wrote them: those that open a thought block of its own (the one its
    // template opens every answer with is not in them), or hold « much » (`MLXChatModel.allowOwnThoughts`).
    let passes = runs.flatMap { $0.raw ?? [] }
    let tokens = runs.flatMap { $0.tokens ?? [] }
    if !passes.isEmpty {
        print("passes as written: with a thought block of the model's own (<|channel>) "
              + share(passes.filter { $0.contains("<|channel>") }.count, passes.count) + " · with « much » "
              + share(tokens.filter { $0.contains { $0.token.trimmingCharacters(in: .whitespaces).lowercased() == "much" } }
                  .count, tokens.count))
    }
}

/// "rrf", "fts2-meaning@0.5": the way of putting the searches together, and the cosine floor of the search by meaning.
func studyFusion(_ text: String) -> (MeaningFusion, Float) {
    let parts = text.split(separator: "@")
    let fusion = MeaningFusion(rawValue: String(parts.first ?? "rrf")) ?? .rrf
    return (fusion, parts.count > 1 ? Float(parts[1]) ?? 0 : 0)
}

/// An earlier report's runs, as far as the replay needs them.
private struct ReplayedRun: Decodable {
    var phrase: String
    var label: String
    var run: Int
    var searches: [Search]
    var found: Bool?
    struct Search: Decodable {
        var texte: String?
        var quand: String?
        var refused: Bool
    }
}

/// The searches an earlier journal-bench report holds (the keywords and periods the model wrote), searched again in each
/// way of the study, without the language model: how often the expected exchange is among the excerpts ("found"), by
/// kind of request. The runs that did not search stay not found.
private func replaySearches(_ path: String, journal: MeaningJournal, corpus: JournalCorpus, corpusID: [Int64: String],
                            dateOf: [String: Date], now: Date, calendar: Calendar, widener: MLXChatModel?) async throws
{
    // The model's own words for each search, asked once (approach 2 of the study: a short pass of its own).
    var widened: [String: String] = [:]
    var passSeconds: [Double] = []
    func widen(_ keywords: String, _ phrase: String) async throws -> String {
        let key = phrase + "|" + keywords
        if let known = widened[key] { return known }
        guard let widener else { return keywords }
        let ask = "L'utilisateur cherche une conversation passée avec toi. Sa demande : « \(phrase) ». Les mots-clés "
            + "de sa recherche : « \(keywords) ». Écris huit à douze mots que cette conversation a pu employer à leur "
            + "place : synonymes, mots plus précis (lieux, plats, objets, métiers, prénoms possibles), mots plus courants "
            + "ou plus familiers. Seulement les mots, séparés par des espaces, sans phrase."
        let start = ContinuousClock.now
        var text = ""
        for try await piece in await widener.reply(to: [ChatMessage(.user, ask)]) {
            if case .text(let t) = piece { text += t }
        }
        passSeconds.append(studyMilliseconds(ContinuousClock.now - start) / 1000)
        let words = SpeakableText.clean(text).replacingOccurrences(of: ",", with: " ")
        let result = keywords + " " + words
        widened[key] = result
        print("   « \(keywords) » → \(words.prefix(160))")
        return result
    }
    let runs = try JSONDecoder().decode([ReplayedRun].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let expectedOf = Dictionary(corpus.requests.map { ($0.phrase, Set($0.expected ?? [])) }, uniquingKeysWith: { a, _ in a })
    let searching = runs.filter { !(expectedOf[$0.phrase] ?? []).isEmpty }
    print("replay of \(path): \(searching.count) runs of requests that must search, "
          + "\(searching.filter { !$0.searches.isEmpty }.count) of them searched")
    var ways: [(String, MeaningFusion, Float, String)] = [("fts (the app)", .fts, 0, "keywords")]
    if widener != nil { ways.append(("fts, keywords widened by the model", .fts, -1, "keywords")) }
    if journal.embedder != nil {
        let floor = journal.embedder?.folder.lastPathComponent.contains("lfm2") == true ? Float(0.2) : Float(0.45)
        for meaningOf in ["keywords", "request", "both"] {
            ways.append(("meaning alone · \(meaningOf)", .meaning, 0, meaningOf))
            ways.append(("meaning alone@\(floor) · \(meaningOf)", .meaning, floor, meaningOf))
            ways.append(("rrf · \(meaningOf)", .rrf, 0, meaningOf))
            ways.append(("fts1-meaning@\(floor) · \(meaningOf)", .ftsOneThenMeaning, floor, meaningOf))
            ways.append(("fts2-meaning@\(floor) · \(meaningOf)", .ftsTwoThenMeaning, floor, meaningOf))
        }
    }
    let groups: [(String, (String) -> Bool)] = [
        ("same words", { $0.contains("same words") }), ("other words", { $0.contains("other words") }),
        ("all", { _ in true }),
    ]
    print("found (the expected exchange among the excerpts), of the runs".padding(toLength: 52, withPad: " ", startingAt: 0)
          + groups.map { $0.0.padding(toLength: 18, withPad: " ", startingAt: 0) }.joined())
    var rows: [[String: Any]] = []
    let originalFusion = await journal.fusion
    for (name, fusion, floor, meaningOf) in ways {
        await journal.setFusion(fusion, cosineFloor: max(0, floor))
        let widenedByModel = floor < 0
        await journal.setMeaningOf(meaningOf)
        var found: [String: (Int, Int)] = [:]
        for run in searching {
            let expected = expectedOf[run.phrase] ?? []
            await journal.setRequest(run.phrase)
            var excerpts: [String] = []
            for search in run.searches where !search.refused {
                let period = search.quand.flatMap { MemoryPeriod.read($0, now: now, calendar: calendar) }
                if search.quand != nil, period == nil { continue }
                var text = search.texte
                if widenedByModel, let keywords = text { text = try await widen(keywords, run.phrase) }
                let hits = try await journal.searchJournal(JournalQuery(text: text, from: period?.start,
                                                                        to: period?.end, limit: 4, now: now))
                excerpts += hits.compactMap { $0.entry.id.flatMap { corpusID[$0] } }
            }
            let hit = excerpts.contains(where: expected.contains)
            for (group, matches) in groups where matches(run.label) {
                let (f, n) = found[group] ?? (0, 0)
                found[group] = (f + (hit ? 1 : 0), n + 1)
            }
        }
        print(name.padding(toLength: 52, withPad: " ", startingAt: 0) + groups.map { group -> String in
            let (f, n) = found[group.0] ?? (0, 0)
            return String(format: "%3d/%-3d %3.0f %%     ", f, n, n == 0 ? 0 : Double(f) * 100 / Double(n))
        }.joined())
        rows.append(["way": name, "found": found.mapValues { [$0.0, $0.1] }])
    }
    await journal.setFusion(originalFusion, cosineFloor: 0)
    _ = rows
    if !passSeconds.isEmpty {
        let sorted = passSeconds.sorted()
        print(String(format: "the model's pass to widen the keywords: median %.2f s, 90th percentile %.2f s (%d passes)",
                     sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))],
                     sorted.count))
    }
}
