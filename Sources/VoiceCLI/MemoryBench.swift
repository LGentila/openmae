// voice-cli memory-bench — how well the memory's journal finds past exchanges, as the app searches it
// (`SQLiteMemoryStore`: FTS5, the query's words folded, stemmed lightly and searched as prefixes, ranked by bm25 with a
// light bonus for recent exchanges). No model, no network.
//
//   voice-cli memory-bench [--corpus Tests/Fixtures/memory-fr.json] [--now 2026-10-15T18:42] [--out measurements]
//                          [--embedder folder [--embedder-cpu]] [--widen-words]
//
// --embedder (the study of issue #167): a sentence-embedding model's folder (MLX, `SentenceEmbedder`): the corpus's
// exchanges embedded as they are written, each query searched by meaning alone and put together with the full-text
// search in several ways (`MeaningFusion`), recall@4 by kind of query, the best cosine of each trap, and the costs (load,
// weights, time per exchange written and per query, a scan of 20,000 vectors); every ranking in a JSON report.
// --widen-words: the keywords widened with the system's French word embedding (`WordWidening`).
//
// The corpus (synthetic) holds about 300 exchanges and 40 queries in five kinds: lexical (the exchange's own words),
// paraphrases (other words), with a period ("la semaine dernière"), as speech-to-text may garble them, and traps (nothing
// to find). For each kind: recall@4 (the share of the expected exchanges among the 4 excerpts the tool gives the model)
// and MRR (1 / the rank of the first expected one). Then the journal grown to 20,000 exchanges (the corpus's, again and
// again over two years): the search's median and 90th-percentile time, and the database's size.
//
// For the decision on searching by meaning: the same queries with the sentence embedding the Mac already has for French
// (`NLEmbedding.sentenceEmbedding`, on the CPU; nothing is downloaded: without it, this part is skipped), alone and fused
// with the full-text ranking (reciprocal rank fusion of each one's 20 best).
//
// Everything is written in a folder of the system's temporary directory, deleted at the end.

import Foundation
import NaturalLanguage
import VoiceCore
import VoiceEngineApple

private struct MemoryCorpus: Decodable {
    var now: String
    var exchanges: [Exchange]
    var queries: [Query]

    struct Exchange: Decodable {
        var id: String
        var date: String
        var user: String
        var answer: String
        var language: String?
    }

    struct Query: Decodable {
        var category: String
        var query: String
        var quand: String?
        var expected: [String]
    }
}

private struct QueryResult: Encodable {
    var category: String
    var query: String
    var quand: String?
    var expected: [String]
    var found: [String]
    var recall: Double?
    var reciprocalRank: Double?
    var ms: Double
}

func runMemoryBench(_ o: Options) async throws {
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/memory-fr.json")
    let corpus = try JSONDecoder().decode(MemoryCorpus.self, from: Data(contentsOf: corpusURL))
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? corpus.now, in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "fr_FR")
    let clock = ContinuousClock()
    let scratch = FileManager.default.temporaryDirectory.appending(path: "openmae-memory-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }

    // 1. The corpus's journal, in date order: the store's ids follow the corpus's.
    let store = try SQLiteMemoryStore(folder: scratch.appending(path: "corpus"))
    var idOf: [Int64: String] = [:]
    for exchange in corpus.exchanges {
        guard let date = LocalDateTime.parse(exchange.date, in: timeZone)?.date else {
            throw CLIError("\(exchange.id): unreadable date \(exchange.date)")
        }
        let id = try await store.addExchange(JournalEntry(
            date: date, user: exchange.user, answer: exchange.answer,
            language: exchange.language == "en" ? .english : .french))
        idOf[id] = exchange.id
    }
    print("journal: \(corpus.exchanges.count) exchanges · \(corpus.queries.count) queries · reference time "
          + LocalDateTime.format(now, in: timeZone))

    var results: [QueryResult] = []
    for query in corpus.queries {
        var period: (start: Date, end: Date)?
        if let quand = query.quand {
            guard let read = MemoryPeriod.read(quand, now: now, calendar: calendar) else {
                throw CLIError("« \(quand) »: a period the app cannot read")
            }
            period = read
        }
        let start = clock.now
        let hits = try await store.searchJournal(JournalQuery(text: query.query, from: period?.start, to: period?.end,
                                                              limit: 4, now: now))
        let ms = milliseconds(clock.now - start)
        let found = hits.compactMap { $0.entry.id.flatMap { idOf[$0] } }
        var result = QueryResult(category: query.category, query: query.query, quand: query.quand,
                                 expected: query.expected, found: found, ms: ms)
        if !query.expected.isEmpty {
            let wanted = Set(query.expected)
            result.recall = Double(found.filter(wanted.contains).count) / Double(min(4, wanted.count))
            result.reciprocalRank = found.firstIndex(where: wanted.contains).map { 1 / Double($0 + 1) } ?? 0
        }
        results.append(result)
        let mark = query.expected.isEmpty ? (found.isEmpty ? "✓" : "·") : (result.recall ?? 0) > 0 ? "✓" : "✗"
        print("\(mark) [\(query.category)] \(query.query)" + (query.quand.map { " (\($0))" } ?? "")
              + " → \(found.isEmpty ? "nothing" : found.joined(separator: ", "))"
              + (query.expected.isEmpty ? "" : " · expected \(query.expected.joined(separator: ", "))"))
    }

    print("\n=== by kind of query (4 excerpts at most) ===")
    let categories = ["lexical", "paraphrase", "period", "transcription", "trap"]
    for category in categories {
        let some = results.filter { $0.category == category }
        guard !some.isEmpty else { continue }
        if category == "trap" {
            let empty = some.filter { $0.found.isEmpty }.count
            print(String(format: "%-14@ %2d queries · nothing found: %d · something found (unrelated): %d",
                         category as NSString, some.count, empty, some.count - empty))
            continue
        }
        let recall = some.compactMap(\.recall).reduce(0, +) / Double(some.count)
        let mrr = some.compactMap(\.reciprocalRank).reduce(0, +) / Double(some.count)
        print(String(format: "%-14@ %2d queries · recall@4 %3.0f %% · MRR %.2f", category as NSString, some.count,
                     recall * 100, mrr))
    }

    // 2. Searching by meaning, for the decision on embeddings.
    if let embedding = NLEmbedding.sentenceEmbedding(for: .french) {
        var dates: [Date] = []
        for exchange in corpus.exchanges { dates.append(LocalDateTime.parse(exchange.date, in: timeZone)!.date) }
        let embedStart = clock.now
        let vectors = corpus.exchanges.map { embedding.vector(for: $0.user + " " + $0.answer) }
        let embedMs = milliseconds(clock.now - embedStart)
        func cosine(_ a: [Double], _ b: [Double]) -> Double {
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in 0..<min(a.count, b.count) {
                dot += a[i] * b[i]
                na += a[i] * a[i]
                nb += b[i] * b[i]
            }
            return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
        }
        var semantic: [String: [Double]] = [:]  // category → recall per query
        var fused: [String: [Double]] = [:]
        for query in corpus.queries where !query.expected.isEmpty {
            let period = query.quand.flatMap { MemoryPeriod.read($0, now: now, calendar: calendar) }
            guard let q = embedding.vector(for: query.query) else { continue }
            let ranked = corpus.exchanges.indices.filter { i in
                period.map { dates[i] >= $0.start && dates[i] < $0.end } ?? true
            }.compactMap { i in vectors[i].map { (corpus.exchanges[i].id, cosine(q, $0)) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
            let wanted = Set(query.expected)
            let recall = { (found: [String]) in Double(found.prefix(4).filter(wanted.contains).count) / Double(min(4, wanted.count)) }
            semantic[query.category, default: []].append(recall(ranked))
            let lexical = try await store.searchJournal(JournalQuery(text: query.query, from: period?.start,
                                                                     to: period?.end, limit: 20, now: now))
                .compactMap { $0.entry.id.flatMap { idOf[$0] } }
            var scores: [String: Double] = [:]
            for (rank, id) in lexical.enumerated() { scores[id, default: 0] += 1 / Double(60 + rank + 1) }
            for (rank, id) in ranked.prefix(20).enumerated() { scores[id, default: 0] += 1 / Double(60 + rank + 1) }
            fused[query.category, default: []].append(recall(scores.sorted { $0.value > $1.value }.map(\.key)))
        }
        print(String(format: "\n=== searching by meaning (NLEmbedding, French sentences, %d dimensions; %d exchanges "
                     + "embedded in %.0f ms) ===", embedding.dimension, corpus.exchanges.count, embedMs))
        for category in categories where category != "trap" {
            let s = semantic[category] ?? [], f = fused[category] ?? []
            guard !s.isEmpty else { continue }
            print(String(format: "%-14@ recall@4 by meaning alone %3.0f %% · fused with the full-text search %3.0f %%",
                         category as NSString, s.reduce(0, +) / Double(s.count) * 100,
                         f.reduce(0, +) / Double(f.count) * 100))
        }
    } else {
        print("\nno French sentence embedding on this Mac: searching by meaning not measured")
    }

    // 2b. The study of issue #167: a sentence-embedding model (--embedder), the keywords widened (--widen-words).
    if o.embedder != nil || o.widenWords {
        try await studyMeaning(o, corpus: corpus, now: now, calendar: calendar, timeZone: timeZone,
                               folder: scratch.appending(path: "meaning"))
    }

    // 3. Speed and size: 20,000 exchanges, the corpus's again and again over two years.
    let big = try SQLiteMemoryStore(folder: scratch.appending(path: "large"))
    let total = 20_000
    var generated: [JournalEntry] = []
    generated.reserveCapacity(total)
    for i in 0..<total {
        let exchange = corpus.exchanges[i % corpus.exchanges.count]
        let date = now.addingTimeInterval(-Double(total - i) / Double(total) * 730 * 86_400)
        generated.append(JournalEntry(date: date, user: exchange.user, answer: exchange.answer,
                                      language: exchange.language == "en" ? .english : .french))
    }
    let insertStart = clock.now
    try await big.addExchanges(generated)
    let insertMs = milliseconds(clock.now - insertStart)
    await big.checkpoint()
    var times: [Double] = []
    for _ in 0..<5 {
        for query in corpus.queries {
            let period = query.quand.flatMap { MemoryPeriod.read($0, now: now, calendar: calendar) }
            let start = clock.now
            _ = try await big.searchJournal(JournalQuery(text: query.query, from: period?.start, to: period?.end,
                                                         limit: 4, now: now))
            times.append(milliseconds(clock.now - start))
        }
    }
    times.sort()
    let median = times[times.count / 2]
    let p90 = times[min(times.count - 1, Int(Double(times.count) * 0.9))]
    let bytes = big.journalBytes
    print("\n=== \(total) exchanges ===")
    print(String(format: "written in %.0f ms (one transaction) · database %.1f MB (%.0f bytes per exchange)", insertMs,
                 Double(bytes) / 1_000_000, Double(bytes) / Double(total)))
    print(String(format: "search: median %.1f ms, 90th percentile %.1f ms, worst %.1f ms (%d searches)", median, p90,
                 times.last ?? 0, times.count))

    let report = o.out.appending(path: "memory-bench-\(Int(Date().timeIntervalSince1970)).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(results).write(to: report)
    print("report: \(report.path)")
}

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// One query of the study, for the analysis outside the app: each search's ranking by the corpus's ids.
private struct MeaningQuery: Encodable {
    var category: String
    var query: String
    var expected: [String]
    var fts: [Ranked]
    var meaning: [Ranked]
    struct Ranked: Encodable {
        var id: String
        var score: Double
    }
}

private struct MeaningReport: Encodable {
    var model: String
    var dimension: Int
    var weightsMB: Double
    var loadSeconds: Double
    var peakMB: Double
    var writeMs: [Double]
    var queryMs: [Double]
    var documentTokens: [Int]
    var widen: Bool
    var queries: [MeaningQuery]
    var scanMs20k: Double
}

/// Searching by meaning (issue #167): the corpus's exchanges embedded as they are written, each query searched in each
/// way of putting the full-text search and the search by meaning together (`MeaningFusion`), recall@4 by kind of query;
/// the costs: the model's load, its memory, the time to embed an exchange and a query, a scan of 20,000 vectors.
private func studyMeaning(_ o: Options, corpus: MemoryCorpus, now: Date, calendar: Calendar, timeZone: TimeZone,
                          folder: URL) async throws
{
    let clock = ContinuousClock()
    var embedder: SentenceEmbedder?
    var loadSeconds = 0.0
    let activeBefore = SentenceEmbedder.activeMemory
    if let path = o.embedder {
        let start = clock.now
        embedder = try await SentenceEmbedder.load(directory: URL(fileURLWithPath: path), cpu: o.embedderCPU)
        loadSeconds = studyMilliseconds(clock.now - start) / 1000
    }
    let name = embedder?.folder.lastPathComponent ?? "none"
    let journal = MeaningJournal(store: try SQLiteMemoryStore(folder: folder), embedder: embedder, fusion: .fts,
                                 meaningOf: "keywords", widen: o.widenWords)
    var corpusID: [Int64: String] = [:]
    var tokens: [Int] = []
    for exchange in corpus.exchanges {
        let id = try await journal.addExchange(JournalEntry(
            date: LocalDateTime.parse(exchange.date, in: timeZone)!.date, user: exchange.user, answer: exchange.answer,
            language: exchange.language == "en" ? .english : .french))
        corpusID[id] = exchange.id
        if let embedder { tokens.append(await embedder.tokenCount(exchange.user + "\n" + exchange.answer, query: false)) }
    }
    let weightsMB = Double(embedder?.weightBytes ?? 0) / 1e6
    let peakMB = Double(SentenceEmbedder.peakMemory - activeBefore) / 1e6
    print("\n=== searching by meaning: \(name)" + (o.embedderCPU ? " (on the CPU)" : "")
          + (o.widenWords ? " · keywords widened with the system's French word embedding" : "") + " ===")
    if let embedder {
        print("prefixes: query « \(embedder.queryPrefix.debugDescription) », exchange « "
              + "\(embedder.documentPrefix.debugDescription) » · \(embedder.dimension) dimensions")
    }

    let floors: [Float] = [0, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    var queries: [MeaningQuery] = []
    var recall: [String: [String: [Double]]] = [:]  // fusion (and floor) → category → recall per query
    var trapsFound: [String: Int] = [:]
    for query in corpus.queries {
        let period = query.quand.flatMap { MemoryPeriod.read($0, now: now, calendar: calendar) }
        let q = JournalQuery(text: query.query, from: period?.start, to: period?.end, limit: 4, now: now)
        let fts = try await journal.fullText(q)
        let meaning = embedder == nil ? [] : try await journal.meaningRanking(q)
        queries.append(MeaningQuery(
            category: query.category, query: query.query, expected: query.expected,
            fts: fts.map { .init(id: corpusID[$0.id] ?? "?", score: $0.score) },
            meaning: meaning.prefix(30).map { .init(id: corpusID[$0.id] ?? "?", score: Double($0.cosine)) }))
        let wanted = Set(query.expected)
        for fusion in MeaningFusion.allCases where embedder != nil || fusion == .fts {
            for floor in (fusion == .ftsTwoThenMeaning || fusion == .strongFTSThenMeaning ? floors : [0]) {
                let key = fusion.rawValue + (floor > 0 ? String(format: "@%.1f", floor) : "")
                let found = fusion.merge(fts: fts, meaning: meaning, limit: 4, cosineFloor: floor)
                    .compactMap { corpusID[$0] }
                if wanted.isEmpty {
                    if !found.isEmpty { trapsFound[key, default: 0] += 1 }
                } else {
                    recall[key, default: [:]][query.category, default: []].append(
                        Double(found.filter(wanted.contains).count) / Double(min(4, wanted.count)))
                }
            }
        }
    }
    let categories = ["lexical", "paraphrase", "period", "transcription"]
    print("recall@4 by kind of query        " + categories.map { $0.padding(toLength: 14, withPad: " ", startingAt: 0) }
        .joined() + "traps with something")
    for key in recall.keys.sorted() {
        let row = categories.map { category -> String in
            let values = recall[key]?[category] ?? []
            return String(format: "%3.0f %%         ", values.reduce(0, +) / Double(max(1, values.count)) * 100)
        }.joined()
        print(key.padding(toLength: 33, withPad: " ", startingAt: 0) + row + "\(trapsFound[key] ?? 0)/8")
    }
    if !meaningTrapCosines(queries).isEmpty {
        print("best cosine, traps: " + meaningTrapCosines(queries))
    }

    // Costs: one exchange written, one query, a scan of 20,000 vectors.
    let writes = await journal.writeMilliseconds.sorted()
    let embeds = await journal.embedMilliseconds.sorted()
    var scanMs = 0.0
    if let embedder {
        let vectors = try await (0..<20).asyncMap { i in
            try await embedder.embed(corpus.exchanges[i].user, query: false)
        }
        let all = (0..<20_000).map { vectors[$0 % vectors.count] }
        let q = try await embedder.embed("le métier de ma sœur", query: true)
        var times: [Double] = []
        for _ in 0..<20 {
            let start = clock.now
            var best: Float = -1
            for v in all { best = max(best, studyDot(q, v)) }
            times.append(studyMilliseconds(clock.now - start))
            if best > 2 { print(best) }
        }
        scanMs = times.sorted()[times.count / 2]
        func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a[a.count / 2] }
        func p90(_ a: [Double]) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * 0.9))] }
        print(String(format: "costs: loaded in %.2f s · weights %.0f MB · peak while embedding %.0f MB above before · "
                     + "an exchange written %.1f ms (median; 90th percentile %.1f; %.0f tokens on average) · a query "
                     + "%.1f ms (median; 90th percentile %.1f) · 20,000 vectors scanned in %.1f ms (%.1f MB as float32)",
                     loadSeconds, weightsMB, peakMB, median(writes), p90(writes),
                     Double(tokens.reduce(0, +)) / Double(max(1, tokens.count)), median(embeds), p90(embeds), scanMs,
                     Double(20_000 * embedder.dimension * 4) / 1e6))
    }
    let report = MeaningReport(model: name, dimension: embedder?.dimension ?? 0, weightsMB: weightsMB,
                               loadSeconds: loadSeconds, peakMB: peakMB, writeMs: writes, queryMs: embeds,
                               documentTokens: tokens, widen: o.widenWords, queries: queries, scanMs20k: scanMs)
    let url = o.out.appending(path: "memory-meaning-\(name)\(o.widenWords ? "-widened" : "")\(o.embedderCPU ? "-cpu" : "").json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: url)
    print("study report: \(url.path)")
}

/// The best cosine the search by meaning gives each trap (a topic the journal never mentions).
private func meaningTrapCosines(_ queries: [MeaningQuery]) -> String {
    queries.filter { $0.expected.isEmpty }.compactMap { $0.meaning.first.map { String(format: "%.2f", $0.score) } }
        .joined(separator: ", ")
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
