import Foundation
import SQLite3
import VoiceCore

/// Maé's memory on disk, in `AppIdentity.memoryDirectory` (or another folder, for voice-cli): the sheet in `memory.md`,
/// a Markdown file the user can read and edit, and the journal in `journal.sqlite`, the system's SQLite with full-text
/// search (FTS5). No network, nothing outside its folder.
///
/// The journal's text is indexed folded (`JournalSearch.indexed`: lower case, no accents, "œ" written "oe"), with the
/// `unicode61 remove_diacritics 2` tokenizer. FTS5 has no French stemmer: the query's words are folded and stemmed
/// lightly, its small words dropped (`JournalSearch.terms`), and each is searched as a prefix, any of them; the matches
/// are ranked by bm25, with a light bonus for recent exchanges (`JournalSearch.score`).
///
/// Beside each exchange, its vector for the search by meaning (`MeaningMemoryStore`), once computed: a row of
/// `exchange_vectors`, the model's name and its 1,024 numbers as float32 (4 KB), erased with the exchange.
public actor SQLiteMemoryStore: JournalVectorStore {
    public nonisolated let folder: URL
    /// The connection, opened once; only used on the actor (and closed by its deinit).
    private nonisolated(unsafe) let db: OpaquePointer?

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public init(folder: URL = AppIdentity.memoryDirectory) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let path = folder.appending(path: "journal.sqlite").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
            == SQLITE_OK
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw Failure(description: "journal: \(message)")
        }
        for statement in [
            "PRAGMA journal_mode = WAL",
            "CREATE TABLE IF NOT EXISTS exchanges (id INTEGER PRIMARY KEY, date REAL NOT NULL, user TEXT NOT NULL, "
                + "answer TEXT NOT NULL, language TEXT NOT NULL, interrupted INTEGER NOT NULL, source TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS exchanges_date ON exchanges(date)",
            "CREATE VIRTUAL TABLE IF NOT EXISTS exchanges_text USING fts5(user, answer, "
                + "tokenize = 'unicode61 remove_diacritics 2')",
            "CREATE TABLE IF NOT EXISTS exchange_vectors (id INTEGER PRIMARY KEY, model TEXT NOT NULL, "
                + "vector BLOB NOT NULL)",
        ] {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                sqlite3_close(handle)
                throw Failure(description: "journal: \(message)")
            }
        }
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: The sheet

    private var sheetURL: URL { folder.appending(path: "memory.md") }

    public func loadSheet() throws -> [String] {
        guard let text = try? String(contentsOf: sheetURL, encoding: .utf8) else { return [] }
        return MemorySheet.entries(fromMarkdown: text)
    }

    public func saveSheet(_ entries: [String]) throws {
        try MemorySheet(entries: entries).markdown.write(to: sheetURL, atomically: true, encoding: .utf8)
    }

    // MARK: The journal

    @discardableResult
    public func addExchange(_ entry: JournalEntry) throws -> Int64 {
        try execute("BEGIN")
        do {
            try run("INSERT INTO exchanges (date, user, answer, language, interrupted, source) VALUES (?, ?, ?, ?, ?, ?)",
                    [.double(entry.date.timeIntervalSince1970), .text(entry.user), .text(entry.answer),
                     .text(entry.language.rawValue), .int(entry.interrupted ? 1 : 0), .text(entry.source.rawValue)])
            let id = sqlite3_last_insert_rowid(db)
            try run("INSERT INTO exchanges_text (rowid, user, answer) VALUES (?, ?, ?)",
                    [.int(id), .text(JournalSearch.indexed(entry.user)), .text(JournalSearch.indexed(entry.answer))])
            try execute("COMMIT")
            return id
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Several exchanges in one transaction (voice-cli's benchmark).
    public func addExchanges(_ entries: [JournalEntry]) throws {
        try execute("BEGIN")
        do {
            for entry in entries {
                try run("INSERT INTO exchanges (date, user, answer, language, interrupted, source) VALUES (?, ?, ?, ?, ?, ?)",
                        [.double(entry.date.timeIntervalSince1970), .text(entry.user), .text(entry.answer),
                         .text(entry.language.rawValue), .int(entry.interrupted ? 1 : 0), .text(entry.source.rawValue)])
                let id = sqlite3_last_insert_rowid(db)
                try run("INSERT INTO exchanges_text (rowid, user, answer) VALUES (?, ?, ?)",
                        [.int(id), .text(JournalSearch.indexed(entry.user)), .text(JournalSearch.indexed(entry.answer))])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func searchJournal(_ query: JournalQuery) throws -> [JournalHit] {
        let from = query.from?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        let to = query.to?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        let terms = JournalSearch.terms(query.text ?? "")
        guard !terms.isEmpty else {
            return try rows("SELECT id, date, user, answer, language, interrupted, source, 0 FROM exchanges "
                            + "WHERE date >= ? AND date < ? ORDER BY date DESC LIMIT ?",
                            [.double(from), .double(to), .int(Int64(query.limit))])
                .map { JournalHit(entry: $0.entry, score: 0) }
        }
        // Each term as a prefix, any of them: "allergi"* OR "noix"*.
        let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
        // More candidates than asked: the bonus of recent exchanges may reorder them.
        let found = try rows("SELECT e.id, e.date, e.user, e.answer, e.language, e.interrupted, e.source, "
                             + "bm25(exchanges_text) FROM exchanges_text JOIN exchanges e ON e.id = exchanges_text.rowid "
                             + "WHERE exchanges_text MATCH ? AND e.date >= ? AND e.date < ? "
                             + "ORDER BY bm25(exchanges_text) LIMIT ?",
                             [.text(match), .double(from), .double(to), .int(Int64(max(20, query.limit * 5)))])
        return Array(found.map { row in
            JournalHit(entry: row.entry, score: JournalSearch.score(relevance: -row.rank, date: row.entry.date,
                                                                    now: query.now))
        }.sorted { $0.score > $1.score }.prefix(query.limit))
    }

    public func countJournal(from: Date?, to: Date?) throws -> Int {
        let (clause, values) = Self.period(from, to)
        return Int(try scalar("SELECT COUNT(*) FROM exchanges" + clause, values))
    }

    @discardableResult
    public func deleteJournal(from: Date?, to: Date?) throws -> Int {
        let (clause, values) = Self.period(from, to)
        try execute("BEGIN")
        do {
            try run("DELETE FROM exchanges_text WHERE rowid IN (SELECT id FROM exchanges" + clause + ")", values)
            try run("DELETE FROM exchange_vectors WHERE id IN (SELECT id FROM exchanges" + clause + ")", values)
            try run("DELETE FROM exchanges" + clause, values)
            let count = Int(sqlite3_changes(db))
            try execute("COMMIT")
            return count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func deleteJournal(ids: [Int64]) throws -> Int {
        var count = 0
        for id in ids {
            try run("DELETE FROM exchanges_text WHERE rowid = ?", [.int(id)])
            try run("DELETE FROM exchange_vectors WHERE id = ?", [.int(id)])
            try run("DELETE FROM exchanges WHERE id = ?", [.int(id)])
            count += Int(sqlite3_changes(db))
        }
        return count
    }

    // MARK: The vectors

    public func journalVectors(model: String, from: Date?, to: Date?) throws -> [Int64: [Float]] {
        let statement = try prepare(
            "SELECT v.id, v.vector FROM exchange_vectors v JOIN exchanges e ON e.id = v.id "
                + "WHERE v.model = ? AND e.date >= ? AND e.date < ?",
            [.text(model), .double(from?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude),
             .double(to?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)])
        defer { sqlite3_finalize(statement) }
        var vectors: [Int64: [Float]] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
            let bytes = Int(sqlite3_column_bytes(statement, 1))
            guard bytes > 0, let blob = sqlite3_column_blob(statement, 1) else { continue }
            var vector = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            vector.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: blob, count: $0.count)) }
            vectors[sqlite3_column_int64(statement, 0)] = vector
        }
        return vectors
    }

    public func saveJournalVector(_ vector: [Float], id: Int64, model: String) throws {
        let data = vector.withUnsafeBytes { Data($0) }
        try run("INSERT OR REPLACE INTO exchange_vectors (id, model, vector) "
                + "SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM exchanges WHERE id = ?)",
                [.int(id), .text(model), .blob(data), .int(id)])
    }

    public func journalWithoutVector(model: String, limit: Int) throws -> [JournalEntry] {
        try rows("SELECT e.id, e.date, e.user, e.answer, e.language, e.interrupted, e.source, 0 FROM exchanges e "
                 + "LEFT JOIN exchange_vectors v ON v.id = e.id AND v.model = ? WHERE v.id IS NULL "
                 + "ORDER BY e.id DESC LIMIT ?", [.text(model), .int(Int64(limit))]).map(\.entry)
    }

    public func journalEntries(ids: [Int64]) throws -> [JournalEntry] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try rows("SELECT id, date, user, answer, language, interrupted, source, 0 FROM exchanges "
                        + "WHERE id IN (\(marks))", ids.map { .int($0) }).map(\.entry)
    }

    /// How many exchanges have a vector of `model` (voice-cli's benches).
    public func vectorCount(model: String) throws -> Int {
        Int(try scalar("SELECT COUNT(*) FROM exchange_vectors WHERE model = ?", [.text(model)]))
    }

    /// The journal's size on disk, in bytes (the database and its write-ahead log).
    public nonisolated var journalBytes: Int64 {
        ["journal.sqlite", "journal.sqlite-wal"].reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)[.size])
                as? Int64
            return total + (size ?? 0)
        }
    }

    /// Writes the write-ahead log into the database (for measuring its size).
    public func checkpoint() {
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    // MARK: SQLite

    private enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    private static func period(_ from: Date?, _ to: Date?) -> (String, [Value]) {
        switch (from, to) {
        case (nil, nil): ("", [])
        case (let from?, nil): (" WHERE date >= ?", [.double(from.timeIntervalSince1970)])
        case (nil, let to?): (" WHERE date < ?", [.double(to.timeIntervalSince1970)])
        case (let from?, let to?): (" WHERE date >= ? AND date < ?", [.double(from.timeIntervalSince1970),
                                                                       .double(to.timeIntervalSince1970)])
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, i, v)
            case .double(let v): sqlite3_bind_double(statement, i, v)
            case .text(let v): sqlite3_bind_text(statement, i, v, -1, transient)
            case .blob(let v):
                v.withUnsafeBytes { _ = sqlite3_bind_blob(statement, i, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ sql: String, _ values: [Value]) throws -> Int64 {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func rows(_ sql: String, _ values: [Value]) throws -> [(entry: JournalEntry, rank: Double)] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var found: [(JournalEntry, Double)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let entry = JournalEntry(
                id: sqlite3_column_int64(statement, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), user: text(2), answer: text(3),
                language: SpeechLanguage(rawValue: text(4)) ?? .french, interrupted: sqlite3_column_int(statement, 5) != 0,
                source: JournalEntry.Source(rawValue: text(6)) ?? .normal)
            found.append((entry, sqlite3_column_double(statement, 7)))
        }
        return found
    }
}

/// The app's memory store, opened on first use: nothing is created on disk while the memory stays off.
public actor LazyMemoryStore: JournalVectorStore {
    public nonisolated let folder: URL
    private var opened: SQLiteMemoryStore?

    public init(folder: URL = AppIdentity.memoryDirectory) {
        self.folder = folder
    }

    /// Whether the memory's folder exists (it was switched on once).
    public nonisolated var exists: Bool { FileManager.default.fileExists(atPath: folder.path) }

    private func store() throws -> SQLiteMemoryStore {
        if let opened { return opened }
        let store = try SQLiteMemoryStore(folder: folder)
        opened = store
        return store
    }

    public func loadSheet() async throws -> [String] { try await store().loadSheet() }
    public func saveSheet(_ entries: [String]) async throws { try await store().saveSheet(entries) }
    @discardableResult
    public func addExchange(_ entry: JournalEntry) async throws -> Int64 { try await store().addExchange(entry) }
    public func searchJournal(_ query: JournalQuery) async throws -> [JournalHit] {
        try await store().searchJournal(query)
    }
    public func countJournal(from: Date?, to: Date?) async throws -> Int {
        try await store().countJournal(from: from, to: to)
    }
    @discardableResult
    public func deleteJournal(from: Date?, to: Date?) async throws -> Int {
        try await store().deleteJournal(from: from, to: to)
    }
    @discardableResult
    public func deleteJournal(ids: [Int64]) async throws -> Int { try await store().deleteJournal(ids: ids) }
    public func journalVectors(model: String, from: Date?, to: Date?) async throws -> [Int64: [Float]] {
        try await store().journalVectors(model: model, from: from, to: to)
    }
    public func saveJournalVector(_ vector: [Float], id: Int64, model: String) async throws {
        try await store().saveJournalVector(vector, id: id, model: model)
    }
    public func journalWithoutVector(model: String, limit: Int) async throws -> [JournalEntry] {
        try await store().journalWithoutVector(model: model, limit: limit)
    }
    public func journalEntries(ids: [Int64]) async throws -> [JournalEntry] {
        try await store().journalEntries(ids: ids)
    }
}
