import Foundation

// Searching the memory's journal by meaning, beside its full-text search (issue #167).
//
// The full-text search finds an exchange when the user asks about it with some of its own words; asked in other words
// (« mon voyage au Portugal » for an exchange about Lisbon and the Douro), it found it 0 to 17 % of the time, depending on
// the model (`voice-cli journal-bench`). A sentence-embedding model gives each exchange a vector when it is written, and
// each search two: the model's keywords and the user's own words; the exchanges closest in meaning to either come first,
// then the full-text search's best (`JournalMeaning.merge`). In the app: LFM2.5-Embedding-350M in 4 bits on MLX
// (`ModelCatalog.journalSearch`, `SentenceEmbedder` in VoiceEngineApple), downloaded once the journal is on.
//
// Measured for the choice (M1 Pro, 32 GB; `voice-cli memory-bench` and `journal-bench`): memory-bench's paraphrases
// found among the 4 excerpts 0 → 69 %, the exchange's own words still 100 %; journal-bench's requests in other words
// found 0 → 50 % (Gemma 4 E2B), 11 → 78 % (E4B), 17 → 58–67 % (26B), those with the same words unchanged; about 30 ms per
// search, 25 ms per exchange written, 199 MB of weights.
//
// A period without keywords (`chercher {quand: la semaine dernière}`, which E4B writes for most requests with a period
// since #197's wording of the journal's part): the exchanges closest in meaning to the user's words come first, then
// the period's latest, when their words name what they ask about; a recap (« Qu'est-ce qu'on s'est dit hier ? ») keeps
// the period's latest, latest first (`JournalMeaning.texts`, issue #209). journal-bench on E4B, two runs each:
// requests in other words found 63 → 83 %, used 40 → 50 %; those with the same words found 99 % before and after (one
// search refused in a run of each: its period, « séance de kiné », unreadable); E2B and the 26B nearly always write
// keywords.
//
// Keywords that name only the period or the asking (« nos conversations », « samedi dernier »), which Gemma 4 26B writes
// for some recaps, count as none, in full text too (`JournalMeaning.keywords`, issue #212): such a recap gets the
// period's latest, latest first, as without keywords. Without the model too (not loaded yet, or the app quitting: the
// full-text search alone), where the 26B's searches with such words found nothing at all, 7 of its 32 for four recaps:
// the period's exchanges seldom hold « conversation », « samedi » or « dernier » (issue #213).

/// A sentence-embedding model: a text's vector, of length 1 (the dot product of two is their cosine).
public protocol SentenceEmbedding: Sendable {
    /// Names the model: a vector is only ever compared with vectors of the same model.
    var model: String { get }
    /// `query`: a search's words; otherwise an exchange of the journal (models embed the two with different prefixes).
    func embed(_ text: String, query: Bool) async throws -> [Float]
}

/// How the search by meaning and the full-text search are put together.
public enum JournalMeaning {
    /// Below this cosine, an exchange is not close enough in meaning to be given (with LFM2.5, the exchanges expected for
    /// memory-bench's paraphrases scored 0.26 to 0.44, the best ones for its traps 0.11 to 0.42: no floor separates them,
    /// this one only drops the farthest).
    public static let cosineFloor: Float = 0.2
    /// The exchanges closest in meaning come first, this many at most: Gemma 4 E2B mostly answers from the first excerpts.
    public static let closestFirst = 3

    /// The excerpts' ids, `limit` at most: the `closestFirst` closest in meaning (cosine `cosineFloor` at least), then
    /// the full-text search's, best first (without keywords, the period's latest), then the rest of those close in
    /// meaning. With 4 excerpts, the full-text search's best is always among them: what the exchange's own words find
    /// never loses (a rare name, which the meaning may rank lower). `meaning`: closest first.
    public static func merge(fullText: [Int64], meaning: [(id: Int64, cosine: Float)], limit: Int) -> [Int64] {
        var chosen: [Int64] = []
        func add(_ id: Int64) {
            if chosen.count < limit, !chosen.contains(id) { chosen.append(id) }
        }
        let close = meaning.filter { $0.cosine >= cosineFloor }
        close.prefix(closestFirst).forEach { add($0.id) }
        fullText.forEach(add)
        close.forEach { add($0.id) }
        return chosen
    }

    /// What is embedded of an exchange: the user's words, then Maé's answer.
    public static func document(_ entry: JournalEntry) -> String { entry.user + "\n" + entry.answer }

    /// What a search reads by meaning: the model's keywords (`keywords`) and the user's words (`JournalQuery.request`).
    /// Without keywords (a period alone, or keywords that name nothing), the user's words only when they name what they
    /// ask about (`namesATopic`), and nothing otherwise: the period's latest exchanges answer a recap better than the
    /// meaning of words that name nothing.
    public static func texts(of query: JournalQuery) -> [String] {
        let request = nonEmpty(query.request)
        guard let keywords = Self.keywords(of: query) else {
            return request.map { namesATopic($0) ? [$0] : [] } ?? []
        }
        return [keywords] + (request.map { [$0] } ?? [])
    }

    /// The model's keywords when they name what is searched (`namesATopic`); nil otherwise, as without keywords:
    /// small words only (« tout »), or the period's and the asking's words only (« nos conversations »,
    /// « samedi dernier », « conversation hier »), which Gemma 4 26B wrote in 7 of its 44 searches for four recaps
    /// (« Tu peux me résumer ce qu'on s'est raconté la semaine dernière ? »). Searched, such words gave the few
    /// exchanges that hold them and the closest in meaning to words that name nothing, instead of the period's latest:
    /// none of last week's latest four, 2 of Saturday's 7 exchanges (issue #212); without the model, in full text alone,
    /// nothing at all (issue #213).
    public static func keywords(of query: JournalQuery) -> String? {
        nonEmpty(query.text).flatMap { namesATopic($0) ? $0 : nil }
    }

    /// Whether the user's words name what they ask about, besides when and that it was said: a word that carries
    /// meaning (`MemoryText.contentWords`) other than a period's (`periodWords`, a number), the asking's
    /// (`askingWords`, `askingRoots`) or Maé's name. « La semaine dernière tu m'avais dit quoi ne pas manquer pendant
    /// notre voyage au Portugal ? » does; a recap does not: « Qu'est-ce qu'on s'est dit hier ? », « Tu peux me résumer
    /// ce qu'on s'est raconté la semaine dernière ? ». The exchanges closest in meaning to words that name nothing are
    /// any of the period's: with LFM2.5, « Qu'est-ce qu'on s'est dit hier ? » put the day's first two, the weather and
    /// the cat's night, before its latest (issue #209).
    public static func namesATopic(_ words: String) -> Bool {
        MemoryText.contentWords(words).contains { word in
            !periodWords.contains(word) && !askingWords.contains(word) && !askingRoots.contains { word.hasPrefix($0) }
                && word.range(of: #"^[0-9]+(h[0-9]*|e|er|eme|ieme)?$"#, options: .regularExpression) == nil
        }
    }

    /// The words of a period, folded and stemmed as `MemoryText.contentWords` gives them: « hier », « la semaine
    /// dernière », « samedi soir », « il y a quinze jours », « début septembre », « l'autre jour », « ce mois-ci »
    /// (numbers in digits aside); in English too.
    static let periodWords: Set<String> = Set([
        "hier", "veille", "aujourd", "hui", "matin", "matinee", "midi", "minuit", "soir", "soiree", "nuit", "jour",
        "jours", "journee", "heure", "heures", "semaine", "semaines", "mois", "annee", "annees", "ans", "week", "end",
        "weekend", "dernier", "derniere", "derniers", "dernieres", "dernierement", "recemment", "passe", "passee",
        "passes", "passees", "precedent", "precedente", "autre", "fois", "debut", "fin", "ci", "premier", "premiere",
        "jusqu", "jusque", "partir", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "janvier",
        "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre", "novembre", "decembre",
        "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "quinze", "vingt",
        "trente", "today", "yesterday", "tonight", "morning", "afternoon", "evening", "night", "day", "days", "weeks",
        "month", "months", "year", "years", "last", "ago", "past", "previous", "earlier", "recently", "time", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
        "may", "june", "july", "august", "september", "october", "november", "december", "two", "three", "four", "five",
        "seven", "eight", "nine", "ten",
    ].map(MemoryText.stem))

    /// The other words of a question that names nothing (« quels sujets », « redis-moi », « les choses dites »), Maé's
    /// name and what one calls her with, folded and stemmed.
    static let askingWords: Set<String> = Set([
        "quel", "quelle", "quels", "quelles", "lequel", "laquelle", "lesquels", "lesquelles", "sujet", "sujets",
        "ensemble", "truc", "trucs", "dite", "dites", "dits", "disait", "disions", "disaient", "redis", "redire",
        "repete", "repetes", "repeter", "dialogue", "dialogues", "mae", "ok", "okay", "he", "hey", "bonjour", "salut",
        "remind", "recall", "us",
    ].map(MemoryText.stem))

    /// How the words that say that something was said or asked begin: « raconté », « résumer », « discuté »,
    /// « échangé », « nos conversations », « demandé », « abordé », « parlé » (the forms the small words miss).
    static let askingRoots = ["racont", "resum", "recap", "discut", "discuss", "echang", "convers", "bavard", "parl",
                              "demand", "abord", "evoqu", "mention", "talk", "summar", "ask"]

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Every exchange of `vectors`, closest first (ties: the oldest first), by its best cosine with one of `queries`.
    public static func ranking(queries: [[Float]], vectors: [Int64: [Float]]) -> [(id: Int64, cosine: Float)] {
        guard !queries.isEmpty else { return [] }
        return vectors.map { id, vector in
            (id: id, cosine: queries.map { dot($0, vector) }.max() ?? -1)
        }.sorted { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.id < $1.id }
    }

    /// The cosine of two vectors of length 1.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
            }
        }
        return sum
    }
}

/// The memory's store, with its journal searched by meaning too, once a sentence-embedding model is given
/// (`setEmbedder`); without one, it searches in full text as the store does, keywords that name nothing aside
/// (`JournalMeaning.keywords`).
///
/// The exchanges are embedded in the background, only while that is allowed (`allowIndexing`: the app allows it while
/// nobody speaks and Maé neither thinks nor speaks, so that the GPU it takes never holds up a request or the voice): those
/// written since, then those written before the model came (the latest first), about 25 ms each with LFM2.5 on the
/// reference Mac. A search embeds its two texts at once (about 15 ms each). An exchange without a vector yet is found by
/// the full-text search only.
public actor MeaningMemoryStore: MemoryStore {
    public let store: any JournalVectorStore
    private var embedder: (any SentenceEmbedding)?
    private var indexingAllowed = false
    /// Exchanges may wait for their vector: the indexing loop goes on (or starts) at the next chance.
    private var indexingWanted = false
    private var indexing: Task<Void, Never>?
    /// Embeddings under way (the indexing's, a search's): `windDown` waits for them.
    private var embedding = 0
    private var windingDown = false

    public init(store: any JournalVectorStore) {
        self.store = store
    }

    /// The model the journal is searched with by meaning; nil: the full-text search alone (the model is not there yet,
    /// or the journal is off). The exchanges without a vector of this model are embedded from now on, when allowed.
    public func setEmbedder(_ embedder: (any SentenceEmbedding)?) {
        self.embedder = embedder
        if embedder != nil { indexWhenAllowed() }
    }

    public var searchesByMeaning: Bool { embedder != nil }

    /// Whether the exchanges may be embedded now. Disallowed, the one under way ends, and the rest waits.
    public func allowIndexing(_ allowed: Bool) {
        indexingAllowed = allowed
        if allowed { indexWhenAllowed() }
    }

    /// Embeds what waits for its vector, now, and returns once done (voice-cli's benches and the tests, which allow it
    /// first).
    public func indexNow() async {
        indexWhenAllowed()
        while let indexing { await indexing.value }
    }

    /// Embeds nothing more, for good, and returns once no embedding is under way: the app quits, and a computation still
    /// on the GPU when the process exits can crash it (see `MLXChatModel.windDown`). Searches go on with the full text.
    public func windDown() async {
        windingDown = true
        await indexing?.value
        while embedding > 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: MemoryStore

    public func loadSheet() async throws -> [String] { try await store.loadSheet() }
    public func saveSheet(_ entries: [String]) async throws { try await store.saveSheet(entries) }

    @discardableResult
    public func addExchange(_ entry: JournalEntry) async throws -> Int64 {
        let id = try await store.addExchange(entry)
        indexWhenAllowed()
        return id
    }

    /// With a model: the closest in meaning to the keywords or to the user's words (`JournalQuery.request`), put
    /// together with the full-text search's best (`JournalMeaning.merge`). Without keywords (a period alone, or keywords
    /// that name nothing: `JournalMeaning.keywords`, which are then not searched in full text either): the closest in
    /// meaning to the user's words, then the period's latest, when their words name what they ask about
    /// (`JournalMeaning.texts`); otherwise (a recap, « Qu'est-ce qu'on s'est dit hier ? »), the period's latest
    /// exchanges, as the store gives them. Without a model (not there yet, or winding down), the store's full-text
    /// search, with the same keywords: those that name nothing are not searched there either, so that a recap gets the
    /// period's latest too (issue #213). The search by meaning failing, the full-text search's.
    public func searchJournal(_ query: JournalQuery) async throws -> [JournalHit] {
        var query = query
        query.text = JournalMeaning.keywords(of: query)
        guard let embedder, !windingDown else { return try await store.searchJournal(query) }
        let texts = JournalMeaning.texts(of: query)
        guard !texts.isEmpty else { return try await store.searchJournal(query) }
        var wide = query
        wide.limit = max(20, query.limit)
        let fullText = try await store.searchJournal(wide)
        var meaning: [(id: Int64, cosine: Float)] = []
        do {
            let vectors = try await store.journalVectors(model: embedder.model, from: query.from, to: query.to)
            if !vectors.isEmpty {
                var queries: [[Float]] = []
                for text in texts {
                    queries.append(try await embed(text, query: true, with: embedder))
                }
                meaning = JournalMeaning.ranking(queries: queries, vectors: vectors)
            }
        } catch {
            DebugLog.log("memory: the search by meaning failed (\(error)): the full-text search alone")
        }
        let ids = JournalMeaning.merge(fullText: fullText.compactMap(\.entry.id), meaning: meaning, limit: query.limit)
        var hits: [Int64: JournalHit] = [:]
        for hit in fullText { if let id = hit.entry.id, hits[id] == nil { hits[id] = hit } }
        let cosines = Dictionary(meaning.map { ($0.id, $0.cosine) }, uniquingKeysWith: { first, _ in first })
        let onlyByMeaning = ids.filter { hits[$0] == nil }
        if !onlyByMeaning.isEmpty {
            for entry in try await store.journalEntries(ids: onlyByMeaning) {
                guard let id = entry.id else { continue }
                hits[id] = JournalHit(entry: entry, score: Double(cosines[id] ?? 0))
            }
        }
        return ids.compactMap { hits[$0] }
    }

    public func countJournal(from: Date?, to: Date?) async throws -> Int {
        try await store.countJournal(from: from, to: to)
    }

    @discardableResult
    public func deleteJournal(from: Date?, to: Date?) async throws -> Int {
        try await store.deleteJournal(from: from, to: to)
    }

    @discardableResult
    public func deleteJournal(ids: [Int64]) async throws -> Int { try await store.deleteJournal(ids: ids) }

    // MARK: Embedding

    private func embed(_ text: String, query: Bool, with embedder: any SentenceEmbedding) async throws -> [Float] {
        embedding += 1
        defer { embedding -= 1 }
        return try await embedder.embed(text, query: query)
    }

    private func indexWhenAllowed() {
        indexingWanted = true
        guard indexing == nil, indexingAllowed, embedder != nil, !windingDown else { return }
        indexing = Task { await self.index() }
    }

    /// Embeds the exchanges without a vector, a few at a time, while allowed; stops at the first failure (the next
    /// exchange written, or the next quiet moment, tries again).
    private func index() async {
        var count = 0
        let start = ContinuousClock.now
        loop: while indexingWanted {
            indexingWanted = false
            while indexingAllowed, !windingDown, let embedder {
                let waiting: [JournalEntry]
                do {
                    waiting = try await store.journalWithoutVector(model: embedder.model, limit: 16)
                } catch {
                    DebugLog.log("memory: exchanges to embed not read: \(error)")
                    break loop
                }
                guard !waiting.isEmpty else { break }
                let before = count
                for entry in waiting {
                    guard let id = entry.id else { continue }
                    guard indexingAllowed, !windingDown, self.embedder?.model == embedder.model else {
                        indexingWanted = true  // the rest, at the next chance
                        break loop
                    }
                    do {
                        let vector = try await embed(JournalMeaning.document(entry), query: false, with: embedder)
                        try await store.saveJournalVector(vector, id: id, model: embedder.model)
                        count += 1
                    } catch {
                        DebugLog.log("memory: exchange not embedded: \(error)")
                        break loop
                    }
                }
                if count == before { break loop }  // none of them got its vector: never the same ones again
            }
        }
        if count > 0 { DebugLog.log("memory: \(count) exchanges embedded in \(ContinuousClock.now - start)") }
        indexing = nil
    }
}
