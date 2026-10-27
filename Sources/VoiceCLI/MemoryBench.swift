// voice-cli memory-bench — how well the memory's journal finds past exchanges, as the app searches it: in full text
// (`SQLiteMemoryStore`: FTS5, the query's words folded, stemmed lightly and searched as prefixes, ranked by bm25 with a
// light bonus for recent exchanges) and by meaning (`MeaningMemoryStore`: the app's sentence-embedding model,
// `ModelCatalog.journalSearch`, on the GPU). No language model, no network.
//
//   voice-cli memory-bench [--corpus Tests/Fixtures/memory-fr.json] [--now 2026-10-15T18:42] [--out measurements]
//                          [--full-text | --embedder folder]
//
// --full-text: the full-text search alone, as before the search by meaning (issue #167). --embedder: another
// sentence-embedding model's folder (MLX) than the app's, which must otherwise be on this Mac (`voice-cli download
// --journal-search`).
//
// The corpus (synthetic) holds about 300 exchanges and 40 queries in five kinds: lexical (the exchange's own words),
// paraphrases (other words), with a period ("la semaine dernière"), as speech-to-text may garble them, and traps (nothing
// to find). Each query is the keywords the model would write (memory-bench has no user's words: the search by meaning
// reads the keywords alone). For each kind: recall@4 (the share of the expected exchanges among the 4 excerpts the tool
// gives the model) and MRR (1 / the rank of the first expected one); for the traps, how many got excerpts anyway. With
// the search by meaning, its costs: the model's load and weights, the time to embed an exchange and to search. Then the
// journal grown to 20,000 exchanges (the corpus's, again and again over two years, each with its exchange's vector): the
// search's median and 90th-percentile time, and the database's size.
//
// Everything is written in a folder of the system's temporary directory, deleted at the end.

import Foundation
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

/// The sentence-embedding model the journal is searched with by meaning, as the app has it (`ModelCatalog.journalSearch`,
/// from the models folder), or --embedder's; nil with --full-text.
func journalEmbedder(_ o: Options) async throws -> SentenceEmbedder? {
    guard !o.fullText else { return nil }
    if let path = o.embedder { return try await SentenceEmbedder.load(directory: URL(fileURLWithPath: path)) }
    let models = ModelStore()
    let pack = ModelCatalog.journalSearch
    guard models.isComplete([pack]) else {
        throw CLIError("\(pack.displayName), the model of the journal's search by meaning, is not on this Mac: run "
                       + "“voice-cli download --journal-search” first, or measure the full-text search alone with "
                       + "--full-text")
    }
    return try await SentenceEmbedder.load(directory: models.folder(pack))
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

    // 0. The search by meaning's model, unless --full-text.
    let memoryBefore = SentenceEmbedder.activeMemory
    let loadStart = clock.now
    let embedder = try await journalEmbedder(o)
    let loadSeconds = milliseconds(clock.now - loadStart) / 1000

    // 1. The corpus's journal, in date order: the store's ids follow the corpus's. Its exchanges embedded as the app
    // does it, once written.
    let inner = try SQLiteMemoryStore(folder: scratch.appending(path: "corpus"))
    let store = MeaningMemoryStore(store: inner)
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
    var embedMs: [Double] = []
    if let embedder {
        // One at a time, timed, as the app's background indexing does it (`MeaningMemoryStore`).
        for entry in try await inner.journalWithoutVector(model: embedder.model, limit: .max).reversed() {
            let start = clock.now
            let vector = try await embedder.embed(JournalMeaning.document(entry), query: false)
            embedMs.append(milliseconds(clock.now - start))
            try await inner.saveJournalVector(vector, id: entry.id!, model: embedder.model)
        }
        await store.setEmbedder(embedder)
    }
    print("journal: \(corpus.exchanges.count) exchanges · \(corpus.queries.count) queries · reference time "
          + LocalDateTime.format(now, in: timeZone))
    print("searching " + (embedder.map {
        "in full text and by meaning (\($0.model), the closest \(JournalMeaning.closestFirst) in meaning first, cosine "
            + "\(JournalMeaning.cosineFloor) at least, then the full-text search's best)"
    } ?? "in full text only (--full-text)"))

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
    if let embedder {
        let searches = results.map(\.ms).sorted()
        print(String(format: "\n=== the search by meaning's costs ===\nloaded in %.2f s · %.0f MB of weights (%.0f MB on "
                     + "the GPU at the peak, above what was there before) · %d dimensions\nan exchange embedded: median "
                     + "%.1f ms, 90th percentile %.1f ms · a search (its words embedded, the full-text search, the "
                     + "comparison): median %.1f ms, 90th percentile %.1f ms",
                     loadSeconds, Double(embedder.weightBytes) / 1e6,
                     Double(SentenceEmbedder.peakMemory - memoryBefore) / 1e6, embedder.dimension, median(embedMs),
                     percentile90(embedMs), median(searches), percentile90(searches)))
    }

    // 2. Speed and size: 20,000 exchanges, the corpus's again and again over two years, each with its exchange's vector.
    let bigInner = try SQLiteMemoryStore(folder: scratch.appending(path: "large"))
    let big = MeaningMemoryStore(store: bigInner)
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
    try await bigInner.addExchanges(generated)
    let insertMs = milliseconds(clock.now - insertStart)
    var vectorsMs = 0.0
    if let embedder {
        // Each exchange gets the vector its corpus exchange has: no need to embed 20,000 of them again.
        let corpusVectors = try await inner.journalVectors(model: embedder.model, from: nil, to: nil)
        let corpusIDs = corpusVectors.keys.sorted()
        let vectorsStart = clock.now
        for (offset, entry) in try await bigInner.journalWithoutVector(model: embedder.model, limit: .max)
            .sorted(by: { $0.id! < $1.id! }).enumerated()
        {
            let vector = corpusVectors[corpusIDs[offset % corpusIDs.count]]!
            try await bigInner.saveJournalVector(vector, id: entry.id!, model: embedder.model)
        }
        vectorsMs = milliseconds(clock.now - vectorsStart)
        await big.setEmbedder(embedder)
    }
    await bigInner.checkpoint()
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
    let bytes = bigInner.journalBytes
    print("\n=== \(total) exchanges" + (embedder == nil ? "" : ", each with its vector") + " ===")
    print(String(format: "written in %.0f ms (one transaction)", insertMs)
          + (embedder == nil ? "" : String(format: ", their vectors in %.0f ms (one at a time)", vectorsMs))
          + String(format: " · database %.1f MB (%.0f bytes per exchange)", Double(bytes) / 1_000_000,
                   Double(bytes) / Double(total)))
    print(String(format: "search: median %.1f ms, 90th percentile %.1f ms, worst %.1f ms (%d searches)", median(times),
                 percentile90(times), times.last ?? 0, times.count))

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

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

private func percentile90(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
}
