// The study of searching the memory's journal by meaning (issue #167): the app's full-text search (`SQLiteMemoryStore`)
// with a sentence-embedding model beside it (`SentenceEmbedder`), put together in several ways, and the query's keywords
// widened with the system's French word embedding. For memory-bench --embedder and journal-bench --embedder; the app
// does not use any of it.

import Foundation
import NaturalLanguage
import VoiceCore
import VoiceEngineApple

/// How the full-text search's hits and the search by meaning's are put together into the 4 excerpts the model gets.
enum MeaningFusion: String, CaseIterable {
    /// The full-text search alone, as the app searches (the baseline).
    case fts
    /// The search by meaning alone.
    case meaning
    /// Reciprocal rank fusion (k = 60) of each one's 20 best.
    case rrf
    /// The full-text search's best, then the search by meaning's best (above the cosine floor) that are not among
    /// them, then the rest of the full-text search's: what the exchange's own words find best stays first.
    case ftsOneThenMeaning = "fts1-meaning"
    /// The same with the full-text search's 2 best.
    case ftsTwoThenMeaning = "fts2-meaning"
    /// The full-text search's best hits whose score is at least a third of the best one's, then the search by
    /// meaning's (only those above a cosine floor), then the rest of the full-text search's.
    case strongFTSThenMeaning = "strong-fts-meaning"

    /// The 4 (or `limit`) ids, from the full-text search's ranking (best first, with its scores) and the search by
    /// meaning's (best first, with its cosines).
    func merge(fts: [(id: Int64, score: Double)], meaning: [(id: Int64, cosine: Float)], limit: Int,
               cosineFloor: Float) -> [Int64]
    {
        var chosen: [Int64] = []
        func add(_ id: Int64) { if chosen.count < limit, !chosen.contains(id) { chosen.append(id) } }
        switch self {
        case .fts:
            fts.forEach { add($0.id) }
        case .meaning:
            meaning.filter { $0.cosine >= cosineFloor }.forEach { add($0.id) }
        case .ftsOneThenMeaning:
            fts.prefix(1).forEach { add($0.id) }
            meaning.filter { $0.cosine >= cosineFloor }.forEach { add($0.id) }
            fts.forEach { add($0.id) }
        case .rrf:
            var scores: [Int64: Double] = [:]
            for (rank, hit) in fts.prefix(20).enumerated() { scores[hit.id, default: 0] += 1 / Double(60 + rank + 1) }
            for (rank, hit) in meaning.prefix(20).enumerated() { scores[hit.id, default: 0] += 1 / Double(60 + rank + 1) }
            scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.forEach { add($0.key) }
        case .ftsTwoThenMeaning:
            fts.prefix(2).forEach { add($0.id) }
            meaning.filter { $0.cosine >= cosineFloor }.forEach { add($0.id) }
            fts.forEach { add($0.id) }
        case .strongFTSThenMeaning:
            let best = fts.first?.score ?? 0
            fts.filter { $0.score >= best / 3 }.prefix(limit - 1).forEach { add($0.id) }
            meaning.filter { $0.cosine >= cosineFloor }.forEach { add($0.id) }
            fts.forEach { add($0.id) }
        }
        return chosen
    }
}

/// The app's store, searched by meaning too: each exchange's vector is computed when it is written (its user's words and
/// Maé's answer, as one document), and a search embeds its words (the model's keywords, the user's request, or both) and
/// compares them with every vector of the period. The ranking is then put together with the full-text search's
/// (`MeaningFusion`).
actor MeaningJournal: MemoryStore {
    let store: SQLiteMemoryStore
    let embedder: SentenceEmbedder?
    var fusion: MeaningFusion
    /// "keywords" (the model's), "request" (the user's words), "both" (the best cosine of the two).
    var meaningOf: String
    var widen: Bool
    var cosineFloor: Float = 0
    /// The user's words for the current request (journal-bench sets them before each run).
    var request: String?
    private var vectors: [Int64: [Float]] = [:]
    private var dates: [Int64: Date] = [:]
    private(set) var writeMilliseconds: [Double] = []
    private(set) var searchMilliseconds: [Double] = []
    private(set) var embedMilliseconds: [Double] = []

    init(store: SQLiteMemoryStore, embedder: SentenceEmbedder?, fusion: MeaningFusion, meaningOf: String,
         widen: Bool)
    {
        self.store = store
        self.embedder = embedder
        self.fusion = fusion
        self.meaningOf = meaningOf
        self.widen = widen
    }

    func setRequest(_ text: String?) { request = text }
    func setMeaningOf(_ text: String) { meaningOf = text }
    func setFusion(_ fusion: MeaningFusion, cosineFloor: Float) {
        self.fusion = fusion
        self.cosineFloor = cosineFloor
    }

    func loadSheet() async throws -> [String] { try await store.loadSheet() }
    func saveSheet(_ entries: [String]) async throws { try await store.saveSheet(entries) }

    @discardableResult
    func addExchange(_ entry: JournalEntry) async throws -> Int64 {
        let id = try await store.addExchange(entry)
        dates[id] = entry.date
        if let embedder {
            let start = ContinuousClock.now
            vectors[id] = try await embedder.embed(entry.user + "\n" + entry.answer, query: false)
            writeMilliseconds.append(studyMilliseconds(ContinuousClock.now - start))
        }
        return id
    }

    func countJournal(from: Date?, to: Date?) async throws -> Int { try await store.countJournal(from: from, to: to) }
    func deleteJournal(from: Date?, to: Date?) async throws -> Int { 0 }
    func deleteJournal(ids: [Int64]) async throws -> Int { 0 }

    /// The full-text search's ranking (20 at most), as the app's store gives it, with the keywords widened when asked.
    func fullText(_ query: JournalQuery) async throws -> [(id: Int64, score: Double)] {
        var text = query.text
        if widen, let words = text { text = WordWidening.widened(words) }
        return try await store.searchJournal(JournalQuery(text: text, from: query.from, to: query.to,
                                                          limit: max(20, query.limit), now: query.now))
            .compactMap { hit in hit.entry.id.map { ($0, hit.score) } }
    }

    /// Every exchange of the period, by meaning (best first), for these words.
    func byMeaning(_ text: String, from: Date?, to: Date?) async throws -> [(id: Int64, cosine: Float)] {
        guard let embedder else { return [] }
        let start = ContinuousClock.now
        let q = try await embedder.embed(text, query: true)
        embedMilliseconds.append(studyMilliseconds(ContinuousClock.now - start))
        return vectors.compactMap { id, v -> (id: Int64, cosine: Float)? in
            guard let date = dates[id] else { return nil }
            if let from, date < from { return nil }
            if let to, date >= to { return nil }
            return (id, studyDot(q, v))
        }.sorted { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.id < $1.id }
    }

    /// What the search by meaning reads for this query.
    func meaningRanking(_ query: JournalQuery) async throws -> [(id: Int64, cosine: Float)] {
        let keywords = query.text.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        switch meaningOf {
        case "request":
            guard let text = request ?? keywords else { return [] }
            return try await byMeaning(text, from: query.from, to: query.to)
        case "both":
            var best: [Int64: Float] = [:]
            for text in [keywords, request].compactMap({ $0 }) {
                for hit in try await byMeaning(text, from: query.from, to: query.to) {
                    best[hit.id] = max(best[hit.id] ?? -1, hit.cosine)
                }
            }
            return best.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        default:
            guard let keywords else { return [] }
            return try await byMeaning(keywords, from: query.from, to: query.to)
        }
    }

    func searchJournal(_ query: JournalQuery) async throws -> [JournalHit] {
        let start = ContinuousClock.now
        let terms = JournalSearch.terms(query.text ?? "")
        guard !terms.isEmpty || (meaningOf == "request" && request != nil && fusion != .fts) else {
            return try await store.searchJournal(query)  // a period alone: its latest exchanges
        }
        let fts = try await fullText(query)
        let meaning = fusion == .fts ? [] : try await meaningRanking(query)
        let ids = fusion.merge(fts: fts, meaning: meaning, limit: query.limit, cosineFloor: cosineFloor)
        searchMilliseconds.append(studyMilliseconds(ContinuousClock.now - start))
        // The entries, from the full-text search's hits, or read again by date for those only meaning found.
        var entries: [Int64: JournalEntry] = [:]
        let wide = try await store.searchJournal(JournalQuery(text: nil, from: query.from, to: query.to, limit: 100_000,
                                                              now: query.now))
        for hit in wide { if let id = hit.entry.id { entries[id] = hit.entry } }
        return ids.compactMap { id in entries[id].map { JournalHit(entry: $0, score: 0) } }
    }
}

/// Each keyword widened with its nearest neighbours in the system's French word embedding (`NLEmbedding.wordEmbedding`,
/// on this Mac, nothing downloaded): « Portugal » with « Espagne », « Lisbonne »…, the original words first, 12 terms at
/// most (the store's limit).
enum WordWidening {
    nonisolated(unsafe) static let embedding = NLEmbedding.wordEmbedding(for: .french)
    static let neighbours = 3
    static let maximumDistance = 1.0

    static func widened(_ text: String) -> String {
        guard let embedding else { return text }
        let words = MemoryText.words(text).filter { !MemoryText.stopWords.contains($0) && $0.count > 2 }
        var extra: [String] = []
        for word in words {
            let near = embedding.neighbors(for: word, maximumCount: neighbours)
                .filter { $0.1 <= maximumDistance }.map(\.0)
            extra += near.filter { !words.contains($0) && !extra.contains($0) }
        }
        return ([text] + extra).joined(separator: " ")
    }
}

func studyDot(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
    return sum
}

func studyMilliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
