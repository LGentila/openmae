// voice-cli memory-bench — how well the memory's journal finds past exchanges, as the app searches it
// (`SQLiteMemoryStore`: FTS5, the query's words folded, stemmed lightly and searched as prefixes, ranked by bm25 with a
// light bonus for recent exchanges). No model, no network.
//
//   voice-cli memory-bench [--corpus Tests/Fixtures/memory-fr.json] [--now 2026-10-15T18:42] [--out measurements]
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
