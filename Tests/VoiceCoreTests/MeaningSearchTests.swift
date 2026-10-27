import Foundation
import Testing

@testable import VoiceCore

private let paris = TimeZone(identifier: "Europe/Paris")!
private let now = LocalDateTime.parse("2026-10-15T18:42", in: paris)!.date

/// A pretend sentence-embedding model: one dimension per topic, set when the text holds one of its words, so that
/// « Portugal » and « Lisbonne » are close in meaning without sharing a word.
private actor TopicEmbedder: SentenceEmbedding {
    nonisolated let model = "topics"
    static let topics: [[String]] = [
        ["portugal", "lisbonne", "douro", "voyage"],
        ["levain", "pate mere", "farine"],
        ["poules", "cocottes", "poulailler"],
        ["pluie", "parapluie"],
    ]
    private(set) var embedded: [(text: String, query: Bool)] = []

    func embed(_ text: String, query: Bool) async throws -> [Float] {
        embedded.append((text, query))
        let folded = MemoryText.folded(text)
        var vector = Self.topics.map { words in words.contains { folded.contains($0) } ? Float(1) : 0 }
        vector.append(0.1)  // never all zeros
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }

    var documentsEmbedded: Int { embedded.filter { !$0.query }.count }
    var queriesEmbedded: [String] { embedded.filter(\.query).map(\.text) }
}

private func exchange(_ daysAgo: Double, _ user: String, _ answer: String) -> JournalEntry {
    JournalEntry(date: now.addingTimeInterval(-daysAgo * 86_400), user: user, answer: answer, language: .french)
}

@Suite("Memory: the journal searched by meaning", .serialized)
struct MeaningSearchTests {
    /// A store with three exchanges, embedded.
    private func journal() async throws -> (MeaningMemoryStore, TransientMemoryStore, TopicEmbedder) {
        let inner = TransientMemoryStore()
        let store = MeaningMemoryStore(store: inner)
        try await store.addExchange(exchange(20, "On part à Lisbonne en mai, puis dans la vallée du Douro",
                                             "Super, pense à goûter le porto."))
        try await store.addExchange(exchange(10, "Je nourris mon levain avec de la farine de seigle",
                                             "D'accord, de la farine de seigle."))
        try await store.addExchange(exchange(3, "Il pleut encore", "Oui, prends un parapluie."))
        let embedder = TopicEmbedder()
        await store.setEmbedder(embedder)
        await store.allowIndexing(true)
        await store.indexNow()
        return (store, inner, embedder)
    }

    @Test func theClosestInMeaningComeFirstThenTheFullTextSearchsBest() {
        let meaning: [(id: Int64, cosine: Float)] = [(5, 0.9), (6, 0.5), (7, 0.3), (8, 0.25), (9, 0.1)]
        // The three closest, then the full-text search's best up to 4.
        #expect(JournalMeaning.merge(fullText: [1, 2, 3], meaning: meaning, limit: 4) == [5, 6, 7, 1])
        // An exchange both find comes once; with few full-text hits, the rest of those close in meaning.
        #expect(JournalMeaning.merge(fullText: [6], meaning: meaning, limit: 4) == [5, 6, 7, 8])
        // Below the cosine floor, nothing by meaning: the full-text search's alone.
        #expect(JournalMeaning.merge(fullText: [1, 2], meaning: [(9, 0.1), (10, 0.19)], limit: 4) == [1, 2])
        #expect(JournalMeaning.merge(fullText: [], meaning: [(9, 0.1)], limit: 4).isEmpty)
    }

    @Test func anExchangeAskedAboutInOtherWordsIsFound() async throws {
        let (store, _, embedder) = try await journal()
        #expect(await embedder.documentsEmbedded == 3)
        // « Portugal » is in none of the exchanges: the full-text search alone finds nothing.
        let full = try await store.store.searchJournal(JournalQuery(text: "voyage Portugal", now: now))
        #expect(full.isEmpty)
        let hits = try await store.searchJournal(JournalQuery(text: "voyage Portugal", now: now))
        #expect(hits.first?.entry.user.contains("Lisbonne") == true)
        #expect(hits.count == 1)  // the other two are too far in meaning
        // The exchange's own words still find it first.
        let own = try await store.searchJournal(JournalQuery(text: "farine seigle", now: now))
        #expect(own.first?.entry.user.contains("levain") == true)
    }

    @Test func theUsersOwnWordsAreSearchedByMeaningToo() async throws {
        let (store, _, embedder) = try await journal()
        // The model's keywords miss the topic; the user's words name it.
        let hits = try await store.searchJournal(JournalQuery(
            text: "conseils", now: now, request: "Tu te souviens de ce que je donne à manger à ma pâte mère ?"))
        #expect(hits.first?.entry.user.contains("levain") == true)
        #expect(await embedder.queriesEmbedded == ["conseils", "Tu te souviens de ce que je donne à manger à ma pâte mère ?"])
    }

    @Test func aPeriodStillBoundsTheSearchByMeaning() async throws {
        let (store, _, _) = try await journal()
        let lastWeek = JournalQuery(text: "voyage Portugal", from: now.addingTimeInterval(-7 * 86_400), to: now,
                                    now: now)
        #expect(try await store.searchJournal(lastWeek).isEmpty)
        // A period alone (no keywords): its latest exchanges, as the store gives them.
        let alone = try await store.searchJournal(JournalQuery(text: nil, from: now.addingTimeInterval(-15 * 86_400),
                                                               to: now, now: now))
        #expect(alone.map { String($0.entry.user.prefix(2)) } == ["Il", "Je"])
    }

    @Test func exchangesAreEmbeddedOnlyWhileAllowedAndErasedWithTheirVectors() async throws {
        let (store, inner, embedder) = try await journal()
        await store.allowIndexing(false)
        try await store.addExchange(exchange(1, "Nos cocottes pondent bien", "Tant mieux, des œufs frais."))
        await store.indexNow()  // not allowed: nothing embedded
        #expect(await inner.vectorCount(model: "topics") == 3)
        // Not embedded yet: the full-text search alone finds it.
        #expect(try await store.searchJournal(JournalQuery(text: "poules", now: now)).isEmpty)
        await store.allowIndexing(true)
        await store.indexNow()
        #expect(await inner.vectorCount(model: "topics") == 4)
        #expect(await embedder.documentsEmbedded == 4)
        #expect(try await store.searchJournal(JournalQuery(text: "poules", now: now)).first?.entry.user
            .contains("cocottes") == true)
        // Erased, its vector goes with it.
        try await store.deleteJournal(from: now.addingTimeInterval(-2 * 86_400), to: nil)
        #expect(await inner.vectorCount(model: "topics") == 3)
        try await store.clearJournal()
        #expect(await inner.vectorCount(model: "topics") == 0)
    }

    @Test func withoutAModelTheJournalIsSearchedInFullTextOnly() async throws {
        let (store, _, _) = try await journal()
        await store.setEmbedder(nil)
        #expect(try await store.searchJournal(JournalQuery(text: "voyage Portugal", now: now)).isEmpty)
        #expect(try await store.searchJournal(JournalQuery(text: "Lisbonne", now: now)).count == 1)
    }

    @Test func theToolHandsTheUsersWordsToTheSearch() async throws {
        let (store, _, _) = try await journal()
        let tools = MemoryTools(store: store, enabled: true, journal: true)
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        let call = ToolCall(name: MemoryCatalog.name, arguments: ["action": "chercher", "texte": "conseils"])
        let reply = await runner.handle(call, context: ToolContext(
            now: now, timeZone: paris, language: .french,
            userSaid: ["Qu'est-ce que je t'avais dit sur notre voyage au Portugal ?"]))
        guard case .object(let fields) = reply.forModel, case .array(let excerpts)? = fields["extraits"],
              case .object(let first)? = excerpts.first
        else {
            Issue.record("no excerpts")
            return
        }
        #expect(first["utilisateur"]?.text?.contains("Lisbonne") == true)
    }
}
