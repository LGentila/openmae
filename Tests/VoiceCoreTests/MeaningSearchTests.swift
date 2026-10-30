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
        // A period alone (no keywords), without the user's words: its latest exchanges, as the store gives them.
        let alone = try await store.searchJournal(JournalQuery(text: nil, from: now.addingTimeInterval(-15 * 86_400),
                                                               to: now, now: now))
        #expect(alone.map { String($0.entry.user.prefix(2)) } == ["Il", "Je"])
    }

    /// Six exchanges of the last six days, the trip to Lisbon the oldest, embedded.
    private func week() async throws -> (MeaningMemoryStore, TopicEmbedder) {
        let store = MeaningMemoryStore(store: TransientMemoryStore())
        try await store.addExchange(exchange(6, "On part à Lisbonne en mai", "Super, pense à goûter le porto."))
        try await store.addExchange(exchange(5, "Je nourris mon levain avec de la farine de seigle", "D'accord."))
        try await store.addExchange(exchange(4, "Mets un minuteur de 10 minutes", "C'est parti pour 10 minutes."))
        try await store.addExchange(exchange(3, "Il pleut encore", "Oui, prends un parapluie."))
        try await store.addExchange(exchange(2, "Bonjour Maé", "Bonjour, belle journée à toi."))
        try await store.addExchange(exchange(1, "Il fait combien ce matin ?", "11 degrés et du brouillard."))
        let embedder = TopicEmbedder()
        await store.setEmbedder(embedder)
        await store.allowIndexing(true)
        await store.indexNow()
        return (store, embedder)
    }

    @Test func aPeriodAloneIsRankedByTheUsersWordsWhenTheyNameATopic() async throws {
        let (store, embedder) = try await week()
        let lastWeek = (from: now.addingTimeInterval(-7 * 86_400), to: now)
        // The closest in meaning to the user's words first, then the period's latest.
        let request = "La semaine dernière tu m'avais dit quoi pour notre voyage au Portugal ?"
        let ranked = try await store.searchJournal(JournalQuery(text: nil, from: lastWeek.from, to: lastWeek.to,
                                                                now: now, request: request))
        #expect(ranked.map { String($0.entry.user.prefix(7)) } == ["On part", "Il fait", "Bonjour", "Il pleu"])
        #expect(await embedder.queriesEmbedded == [request])
        // A recap names nothing but the period: its latest exchanges, latest first, its words not embedded.
        let recapWords = "Qu'est-ce qu'on s'est dit cette semaine ?"
        let recap = try await store.searchJournal(JournalQuery(text: nil, from: lastWeek.from, to: lastWeek.to,
                                                               now: now, request: recapWords))
        #expect(recap.map { String($0.entry.user.prefix(7)) } == ["Il fait", "Bonjour", "Il pleu", "Mets un"])
        #expect(await embedder.queriesEmbedded == [request])
        // Keywords that are only small words are no keywords.
        let small = try await store.searchJournal(JournalQuery(text: "tout", from: lastWeek.from, to: lastWeek.to,
                                                               now: now, request: request))
        #expect(small.first?.entry.user.contains("Lisbonne") == true)
    }

    @Test func onlyWordsThatNameATopicRankAPeriod() {
        // journal-bench's requests with a period, and others that name what they ask about.
        for words in [
            "La semaine dernière je t'ai parlé des devis pour la cuisine, c'était combien ?",
            "Hier je t'ai parlé de ma dernière séance de kiné, il m'avait conseillé quoi ?",
            "Avant-hier je t'ai raconté la réunion parents-profs, qu'est-ce que le prof avait dit ?",
            "Le mois dernier je t'avais dit en combien de temps j'avais couru les dix bornes, tu te rappelles ?",
            "La semaine dernière je t'ai dit ce que le mécano avait fait sur la voiture, ça avait coûté combien ?",
            "Hier je t'ai dit quand ma fille montait sur scène, c'est à quelle date ?",
            "Le mois dernier tu m'avais donné une idée de cadeau pour le bébé de Clémence, c'était quoi ?",
            "Samedi dernier tu m'as donné une recette de cookies, tu peux me la redonner ?",
            "Avant-hier tu m'as conseillé un livre pour Gabin, c'était lequel ?",
            "Hier tu m'avais proposé un plat avec du poisson, c'était quoi déjà ?",
            "La semaine dernière tu m'avais dit quoi ne pas manquer pendant notre voyage au Portugal ?",
            "Le mois dernier tu m'avais proposé une activité pour les jours de pluie avec les enfants, c'était quoi ?",
            "Qu'est-ce qu'on s'est dit hier sur la cuisine ?",
            "What did I tell you about the brakes last week?",
        ] {
            #expect(JournalMeaning.namesATopic(words), "\(words)")
        }
        // Recaps: the period, the asking, Maé's name, numbers.
        for words in [
            "Qu'est-ce qu'on s'est dit hier ?",
            "De quoi on a parlé avant-hier ?",
            "Tu peux me résumer ce qu'on s'est raconté la semaine dernière ?",
            "Qu'est-ce que je t'ai dit samedi dernier ?",
            "Maé, rappelle-moi nos conversations d'il y a 3 jours.",
            "Quels sujets on a abordés ce matin ?",
            "Redis-moi ce que je t'ai demandé lundi à 18h30.",
            "On a discuté de quoi le 12 octobre ?",
            "Qu'est-ce qu'on s'est raconté l'autre jour ?",
            "Qu'est-ce que je t'avais dit la semaine passée ?",
            "What did we talk about yesterday?",
        ] {
            #expect(!JournalMeaning.namesATopic(words), "\(words)")
        }
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

    @Test func theToolRanksAPeriodWithoutKeywordsByTheUsersWords() async throws {
        let (store, _) = try await week()
        let tools = MemoryTools(store: store, enabled: true, journal: true)
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        /// The first excerpt a search of this month with no keywords gives, the user having said `said`.
        func firstExcerpt(_ said: String) async -> String? {
            let call = ToolCall(name: MemoryCatalog.name, arguments: ["action": "chercher", "quand": "ce mois-ci"])
            let reply = await runner.handle(call, context: ToolContext(now: now, timeZone: paris, language: .french,
                                                                       userSaid: [said]))
            guard case .object(let fields) = reply.forModel, case .array(let excerpts)? = fields["extraits"],
                  case .object(let first)? = excerpts.first
            else { return nil }
            return first["utilisateur"]?.text
        }
        let asked = await firstExcerpt("Ce mois-ci tu m'avais dit quoi sur notre voyage au Portugal ?")
        #expect(asked?.contains("Lisbonne") == true)
        let recap = await firstExcerpt("Qu'est-ce qu'on s'est dit ce mois-ci ?")
        #expect(recap?.hasPrefix("Il fait combien") == true)
    }
}
