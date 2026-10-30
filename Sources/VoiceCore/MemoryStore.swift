import Foundation

// Maé's memory: a sheet of what the user asked her to remember, and a journal of past exchanges.
//
// The sheet (`memory.md`) is a Markdown file the user can read and edit, one entry per line ("- …"). It goes into the
// beginning of each conversation (`MemoryTools.promptAddendum`), frozen for the conversation so that the model's memory
// of that beginning stays valid. Its size is capped (`MemorySheet.capacity`).
//
// The journal (`journal.sqlite`, `SQLiteMemoryStore` in VoiceEngineApple) keeps one row per exchange the pipeline
// processed: the user's words (without the date line or the English hint), what Maé answered (what the user heard when
// cut off), the language, whether it was cut off, and whether the turn used something from outside (a web search, an
// agent). Searched with full-text search, ranked by relevance with a light bonus for recent exchanges, and by meaning
// too once its sentence-embedding model is there (`MeaningMemoryStore`): a vector per exchange, kept beside it.
//
// Everything stays on this Mac: no network, never in iCloud (`AppIdentity.memoryDirectory`).

/// One exchange of the journal.
public struct JournalEntry: Sendable, Codable, Equatable {
    /// Whether the answer used something from outside the conversation.
    public enum Source: String, Sendable, Codable {
        case normal
        /// The turn used `chercher_web` or an agent's tool: its answer carries words from outside.
        case external
    }

    /// Set by the store.
    public var id: Int64?
    public var date: Date
    /// The user's words, as they said them (no date line, no English hint).
    public var user: String
    /// What Maé answered; what the user heard of it when it was cut off.
    public var answer: String
    public var language: SpeechLanguage
    public var interrupted: Bool
    public var source: Source

    public init(id: Int64? = nil, date: Date, user: String, answer: String, language: SpeechLanguage,
                interrupted: Bool = false, source: Source = .normal)
    {
        self.id = id
        self.date = date
        self.user = user
        self.answer = answer
        self.language = language
        self.interrupted = interrupted
        self.source = source
    }
}

/// A search of the journal: words, a period, or both.
public struct JournalQuery: Sendable, Equatable {
    /// The words to look for (any of them); nil or empty: the period's latest exchanges (searched by meaning too, those
    /// closest to the user's words first when they name what they ask about: `MeaningMemoryStore`).
    public var text: String?
    public var from: Date?
    public var to: Date?
    public var limit: Int
    /// For the bonus of recent exchanges.
    public var now: Date
    /// What the user said when they asked (their words, not the model's keywords): the search by meaning reads it too,
    /// and ranks a period by it when the model wrote no keywords (`MeaningMemoryStore`). nil: the keywords alone.
    public var request: String?

    public init(text: String?, from: Date? = nil, to: Date? = nil, limit: Int = 4, now: Date = Date(),
                request: String? = nil)
    {
        self.text = text
        self.from = from
        self.to = to
        self.limit = limit
        self.now = now
        self.request = request
    }
}

/// An exchange found, with its score (higher is better).
public struct JournalHit: Sendable, Equatable {
    public var entry: JournalEntry
    public var score: Double

    public init(entry: JournalEntry, score: Double) {
        self.entry = entry
        self.score = score
    }
}

/// Where the memory is kept: the sheet and the journal. `SQLiteMemoryStore` (VoiceEngineApple) on disk, in the app;
/// `TransientMemoryStore` in memory, for the tests and voice-cli.
public protocol MemoryStore: Sendable {
    /// The sheet's entries, in order.
    func loadSheet() async throws -> [String]
    /// Writes the whole sheet.
    func saveSheet(_ entries: [String]) async throws
    /// Adds an exchange to the journal; returns its id.
    @discardableResult
    func addExchange(_ entry: JournalEntry) async throws -> Int64
    /// The best exchanges for the query, the best first (at most `limit`).
    func searchJournal(_ query: JournalQuery) async throws -> [JournalHit]
    /// How many exchanges there are between these dates (nil: no bound).
    func countJournal(from: Date?, to: Date?) async throws -> Int
    /// Deletes the exchanges between these dates (nil: no bound; both nil: all of them); returns how many.
    @discardableResult
    func deleteJournal(from: Date?, to: Date?) async throws -> Int
    /// Deletes these exchanges; returns how many.
    @discardableResult
    func deleteJournal(ids: [Int64]) async throws -> Int
}

/// A store that also keeps, for searching the journal by meaning (`MeaningMemoryStore`), one vector per exchange and
/// sentence-embedding model (`SentenceEmbedding.model`), erased with its exchange.
public protocol JournalVectorStore: MemoryStore {
    /// The vectors of `model` of the exchanges between these dates (nil: no bound), by exchange.
    func journalVectors(model: String, from: Date?, to: Date?) async throws -> [Int64: [Float]]
    /// Keeps an exchange's vector, in place of one of another model; nothing when the exchange is no longer there.
    func saveJournalVector(_ vector: [Float], id: Int64, model: String) async throws
    /// Exchanges without a vector of `model` yet, the latest first, `limit` at most.
    func journalWithoutVector(model: String, limit: Int) async throws -> [JournalEntry]
    /// These exchanges, those still there, in any order.
    func journalEntries(ids: [Int64]) async throws -> [JournalEntry]
}

extension MemoryStore {
    /// The sheet: its entries as they are on disk.
    public func sheet() async throws -> [String] { try await loadSheet() }

    /// Adds an entry to the sheet, or says why not (`MemorySheet.Problem`).
    public func addToSheet(_ entry: String) async throws {
        var sheet = MemorySheet(entries: try await loadSheet())
        try sheet.add(entry)
        try await saveSheet(sheet.entries)
    }

    /// Removes an entry of the sheet (the same, whatever the case, accents and spaces); false when it was not there.
    @discardableResult
    public func removeFromSheet(_ entry: String) async throws -> Bool {
        var sheet = MemorySheet(entries: try await loadSheet())
        guard sheet.remove(entry) else { return false }
        try await saveSheet(sheet.entries)
        return true
    }

    public func clearSheet() async throws { try await saveSheet([]) }

    /// Forgets the exchanges older than `days` days before `now`; returns how many.
    @discardableResult
    public func purgeJournal(keepingDays days: Int, now: Date = Date()) async throws -> Int {
        try await deleteJournal(from: nil, to: now.addingTimeInterval(-Double(days) * 86_400))
    }

    public func clearJournal() async throws { try await deleteJournal(from: nil, to: nil) }

    /// The sheet and the journal, erased.
    public func eraseAll() async throws {
        try await clearSheet()
        try await clearJournal()
    }
}

/// The sheet's rules: one line per entry, 200 characters at most, no entry twice, 1,200 characters in all.
public struct MemorySheet: Sendable, Equatable {
    /// The sheet's limit, in characters (its entries, without the "- " of the file).
    public static let capacity = 1_200
    /// One entry's limit.
    public static let entryLimit = 200

    public enum Problem: Error, Sendable, Equatable {
        case empty
        case tooLong
        /// The same entry is already there (whatever the case, accents and spaces).
        case duplicate
        /// The sheet has no room for it.
        case full
    }

    public private(set) var entries: [String]

    public init(entries: [String] = []) {
        self.entries = entries
    }

    /// Characters the entries take.
    public var characters: Int { entries.reduce(0) { $0 + $1.count } }

    /// The entry as the sheet keeps it: one line, spaces trimmed.
    public static func cleaned(_ entry: String) -> String {
        entry.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func add(_ entry: String) throws {
        let entry = Self.cleaned(entry)
        guard !entry.isEmpty else { throw Problem.empty }
        guard entry.count <= Self.entryLimit else { throw Problem.tooLong }
        let key = MemoryText.key(entry)
        guard !entries.contains(where: { MemoryText.key($0) == key }) else { throw Problem.duplicate }
        guard characters + entry.count <= Self.capacity else { throw Problem.full }
        entries.append(entry)
    }

    @discardableResult
    public mutating func remove(_ entry: String) -> Bool {
        let key = MemoryText.key(entry)
        guard let index = entries.firstIndex(where: { MemoryText.key($0) == key }) else { return false }
        entries.remove(at: index)
        return true
    }

    // MARK: The file

    /// The file's text: a title, a line for the user, then one "- entry" per line.
    public var markdown: String {
        var text = "# Mémoire\n\n<!-- Ce que tu as demandé à Maé de retenir, une ligne par entrée. "
            + "Tu peux modifier ce fichier : Maé le relit à chaque nouvelle conversation. -->\n\n"
        text += entries.map { "- \($0)\n" }.joined()
        return text
    }

    /// The entries of a file: its "- " lines, or any other line that is not a title or a comment (the user may have
    /// written one without the dash). At most `capacity` characters are read, in order.
    public static func entries(fromMarkdown text: String) -> [String] {
        var entries: [String] = []
        var inComment = false
        var total = 0
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                if !line.contains("-->") { inComment = true }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            line = cleaned(line)
            guard !line.isEmpty else { continue }
            let entry = String(line.prefix(entryLimit))
            guard total + entry.count <= capacity else { break }
            guard !entries.contains(where: { MemoryText.key($0) == MemoryText.key(entry) }) else { continue }
            entries.append(entry)
            total += entry.count
        }
        return entries
    }
}

/// How the memory compares words: lower case, no accents, "œ" as "oe", apostrophes and dashes as spaces; the small words
/// set aside (articles, pronouns, the verbs that say nothing on their own); plurals and a final "e" taken off.
public enum MemoryText {
    /// The text folded: lower case, no accents, ligatures written out, only letters and digits between spaces.
    public static func folded(_ text: String) -> String {
        let lower = text.lowercased()
            .replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        let scalars = lower.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// The folded words.
    public static func words(_ text: String) -> [String] {
        folded(text).split(separator: " ").map(String.init)
    }

    /// A key for comparing entries: the folded words, in order.
    public static func key(_ text: String) -> String { words(text).joined(separator: " ") }

    /// The words that carry meaning, stemmed (`stem`), small words aside.
    public static func contentWords(_ text: String) -> [String] {
        words(text).filter { !stopWords.contains($0) && ($0.count > 1 || $0.first?.isNumber == true) }.map(stem)
    }

    /// A light stem: the plural's "s" or "x", then a final "e", taken off longer words ("allergies" → "allergi",
    /// "allergique" → "allergiqu"). Enough for a prefix search to find the singular and the plural.
    public static func stem(_ word: String) -> String {
        var w = word
        if w.count > 4, w.hasSuffix("s") || w.hasSuffix("x") { w.removeLast() }
        if w.count > 4, w.hasSuffix("e") { w.removeLast() }
        return w
    }

    /// Small words, French and English, folded: articles, pronouns, prepositions, the verbs and adverbs that say
    /// nothing on their own, and what one says to ask Maé to remember or search ("retiens", "souviens").
    public static let stopWords: Set<String> = [
        "a", "au", "aux", "avec", "c", "ca", "ce", "ces", "cet", "cette", "d", "dans", "de", "des", "du", "elle",
        "elles", "en", "es", "est", "et", "etait", "etais", "ete", "etre", "eu", "il", "ils", "j", "je", "l", "la",
        "le", "les", "leur", "leurs", "lui", "m", "ma", "mais", "me", "mes", "moi", "mon", "n", "ne", "nos", "notre",
        "nous", "on", "ou", "par", "pas", "pour", "qu", "que", "qui", "s", "sa", "se", "ses", "si", "son", "sont",
        "suis", "sur", "t", "ta", "te", "tes", "toi", "ton", "tu", "un", "une", "vos", "votre", "vous", "y", "ai",
        "as", "avait", "avais", "avez", "avons", "ont", "fait", "faire", "dit", "dire", "quoi", "quand", "comment",
        "dont", "lors", "tout", "tous", "toute", "toutes", "tres", "plus", "moins", "bien", "aussi", "alors", "donc",
        "puis", "deja", "encore", "jamais", "toujours", "rien", "chose", "choses", "quelque", "quelques", "peu",
        "beaucoup", "oui", "non", "est-ce", "estce", "ceci", "cela", "celui", "celle", "ici", "la-bas", "parce",
        "car", "comme", "entre", "chez", "sans", "sous", "vers", "apres", "avant", "depuis", "pendant",
        "utilisateur", "utilisatrice", "retiens", "retenir", "retenu", "souviens", "souvenir", "rappelle",
        "rappeler", "rappelles", "note", "noter", "memoire", "memorise", "memoriser", "oublie", "oublier", "cherche",
        "chercher", "retrouve", "retrouver", "dis", "disais", "parle", "parler", "parlais", "parlait", "avions",
        "aviez", "etions", "sais", "savoir", "veux", "voudrais", "peux", "pourrais", "dois", "faut", "merci", "stp",
        "svp", "please", "the", "an", "and", "or", "of", "to", "in", "at", "for", "with", "is", "are", "was", "were",
        "be", "been", "i", "my", "mine", "you", "your", "he", "she", "it", "its", "we", "our", "they", "their",
        "them", "that", "this", "these", "those", "what", "which", "who", "whom", "do", "does", "did", "have", "has",
        "had", "not", "no", "yes", "about", "from", "by", "so", "but", "if", "then", "than", "too", "very", "just",
        "remember", "forget", "told", "tell", "said", "say", "search", "find", "can", "could", "would", "should",
        "will",
    ]
}

/// The memory kept in this process only: for the tests and voice-cli (not the CLI's `MemoryCalendar`, which keeps
/// events and reminders). Searches like the app's store: any of the query's words, as prefixes, ranked by BM25 with the
/// same light bonus for recent exchanges; keeps the exchanges' vectors as it does.
public actor TransientMemoryStore: JournalVectorStore {
    private var sheetEntries: [String]
    private var rows: [JournalEntry] = []
    private var nextID: Int64 = 1
    private var vectors: [Int64: (model: String, vector: [Float])] = [:]

    public init(sheet: [String] = []) {
        sheetEntries = sheet
    }

    public func loadSheet() -> [String] { sheetEntries }
    public func saveSheet(_ entries: [String]) { sheetEntries = entries }

    @discardableResult
    public func addExchange(_ entry: JournalEntry) -> Int64 {
        var entry = entry
        entry.id = nextID
        nextID += 1
        rows.append(entry)
        return entry.id!
    }

    /// Every exchange, the oldest first.
    public var journal: [JournalEntry] { rows }

    public func searchJournal(_ query: JournalQuery) -> [JournalHit] {
        let inPeriod = rows.filter { Self.within($0.date, from: query.from, to: query.to) }
        let terms = JournalSearch.terms(query.text ?? "")
        guard !terms.isEmpty else {
            return inPeriod.sorted { $0.date > $1.date }.prefix(query.limit).map { JournalHit(entry: $0, score: 0) }
        }
        let documents = inPeriod.map { JournalSearch.indexed($0.user + " " + $0.answer).split(separator: " ").map(String.init) }
        let totalWords = documents.reduce(0) { $0 + $1.count }
        let averageLength: Double = max(1, Double(totalWords) / Double(max(1, documents.count)))
        var hits: [JournalHit] = []
        for (row, words) in zip(inPeriod, documents) {
            var relevance = 0.0
            for term in terms {
                let frequency = Double(words.filter { $0.hasPrefix(term) }.count)
                guard frequency > 0 else { continue }
                let containing = Double(documents.filter { $0.contains { $0.hasPrefix(term) } }.count)
                let total = Double(documents.count)
                let idf: Double = log(1 + (total - containing + 0.5) / (containing + 0.5))
                let k1 = 1.2
                let b = 0.75
                let length: Double = Double(words.count) / averageLength
                let norm: Double = frequency + k1 * (1 - b + b * length)
                relevance += idf * frequency * (k1 + 1) / norm
            }
            guard relevance > 0 else { continue }
            hits.append(JournalHit(entry: row, score: JournalSearch.score(relevance: relevance, date: row.date,
                                                                          now: query.now)))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(query.limit))
    }

    public func countJournal(from: Date?, to: Date?) -> Int {
        rows.filter { Self.within($0.date, from: from, to: to) }.count
    }

    private static func within(_ date: Date, from: Date?, to: Date?) -> Bool {
        if let from, date < from { return false }
        if let to, date >= to { return false }
        return true
    }

    @discardableResult
    public func deleteJournal(from: Date?, to: Date?) -> Int {
        let before = rows.count
        rows.removeAll { Self.within($0.date, from: from, to: to) }
        dropVectorsOfErasedExchanges()
        return before - rows.count
    }

    @discardableResult
    public func deleteJournal(ids: [Int64]) -> Int {
        let before = rows.count
        let ids = Set(ids)
        rows.removeAll { $0.id.map(ids.contains) ?? false }
        dropVectorsOfErasedExchanges()
        return before - rows.count
    }

    private func dropVectorsOfErasedExchanges() {
        let kept = Set(rows.compactMap(\.id))
        vectors = vectors.filter { kept.contains($0.key) }
    }

    // MARK: Vectors

    public func journalVectors(model: String, from: Date?, to: Date?) -> [Int64: [Float]] {
        var found: [Int64: [Float]] = [:]
        for row in rows where Self.within(row.date, from: from, to: to) {
            if let id = row.id, let kept = vectors[id], kept.model == model { found[id] = kept.vector }
        }
        return found
    }

    public func saveJournalVector(_ vector: [Float], id: Int64, model: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        vectors[id] = (model, vector)
    }

    public func journalWithoutVector(model: String, limit: Int) -> [JournalEntry] {
        Array(rows.reversed().filter { row in row.id.map { vectors[$0]?.model != model } ?? false }.prefix(limit))
    }

    public func journalEntries(ids: [Int64]) -> [JournalEntry] {
        let ids = Set(ids)
        return rows.filter { $0.id.map(ids.contains) ?? false }
    }

    /// How many exchanges have a vector of `model` (the tests).
    public func vectorCount(model: String) -> Int { vectors.values.filter { $0.model == model }.count }
}

/// What the stores share for the journal's search.
public enum JournalSearch {
    /// The query's terms: its content words, stemmed (`MemoryText`), each searched as a prefix; at most 12.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return MemoryText.contentWords(text).filter { seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    /// The text as it is indexed: folded (`MemoryText.folded`), every word kept.
    public static func indexed(_ text: String) -> String { MemoryText.folded(text) }

    /// How much more a recent exchange counts: up to 15 % for today, half of that after three weeks.
    public static let recencyBonus = 0.15
    public static let recencyHalfLifeDays = 21.0

    /// Relevance (positive, higher is better), with the bonus of recent exchanges.
    public static func score(relevance: Double, date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return relevance * (1 + recencyBonus * pow(0.5, days / recencyHalfLifeDays))
    }
}
