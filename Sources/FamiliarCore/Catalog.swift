import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum CatalogError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        if case .sqlite(let message) = self { return "Index database: \(message)" }
        return nil
    }
}

/// One piece of a file that has a vector: a text chunk, a PDF page, a picture, a video frame, 30 s of sound.
public struct SegmentRow: Sendable {
    public var kind: SegmentKind
    /// Page index for PDF pages, seconds for audio and video, the chunk's character offset for text.
    public var locator: Double
    /// A short excerpt shown under the result (text kinds only).
    public var snippet: String?
    public var vector: [Float]

    public init(kind: SegmentKind, locator: Double, snippet: String?, vector: [Float]) {
        self.kind = kind; self.locator = locator; self.snippet = snippet; self.vector = vector
    }
}

public enum SegmentKind: String, Sendable {
    case text, page, pageImage, image, frame, audio
}

/// Text for the keyword index: exact words (invoice numbers, names, error codes) that embeddings don't hold.
public struct KeywordRow: Sendable {
    public var text: String
    public var locator: Double
    public var kind: SegmentKind
    public init(text: String, locator: Double, kind: SegmentKind) { self.text = text; self.locator = locator; self.kind = kind }
}

public struct FileState: Sendable {
    public let id: Int64
    public let size: Int64
    public let mtime: Double
}

public struct SegmentInfo: Sendable {
    public let segmentID: Int64
    public let fileID: Int64
    public let path: String
    public let fileKind: String
    public let kind: SegmentKind
    public let locator: Double
    public let snippet: String?
}

public struct IndexCounts: Sendable {
    public var files = 0
    public var failed = 0
    public var segments = 0
    public var byKind: [String: Int] = [:]
    public init() {}
}

/// The index: one SQLite file with every file's segments and their vectors, plus an FTS5 keyword index.
/// All access goes through one connection behind a lock.
public final class Catalog: @unchecked Sendable {
    public static let schemaVersion = 1
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Bumped on every change, so search knows when to update its vectors.
    public private(set) var generation = 0
    /// Every segment id deleted since this Catalog opened, in order: search drops these rows from memory instead of
    /// reloading everything (`removedSegments(after:)`).
    private var removedLog: [Int64] = []
    /// How many entries were trimmed off the front of `removedLog` (a reader further behind must reload in full).
    private var removedLogStart = 0
    /// Bumped when the index is emptied, or the removal log trimmed: every reader reloads in full.
    public private(set) var resetCount = 0
    private var pendingRemovals: [Int64] = []
    public let url: URL
    /// Called once when SQLite reports the file damaged (SQLITE_CORRUPT, SQLITE_NOTADB) during use; the app then calls
    /// `recover()`. Damage found while opening is recovered from right away.
    public var onDamage: (@Sendable () -> Void)?
    private var damageReported = false
    /// Set when opening found the file damaged and replaced it: the app says so and reads every folder again.
    public private(set) var recoveredAtOpen = false

    public init(url: URL = AppPaths.index) throws {
        self.url = url
        do {
            try open()
        } catch where isDamage(sqlite3_errcode(db)) {
            try moveAsideAndReopen()
            recoveredAtOpen = true
        }
    }

    private func open() throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK else {
            throw CatalogError.sqlite("can't open \(url.path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS files(
              id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
              size INTEGER NOT NULL, mtime REAL NOT NULL, indexed_at REAL NOT NULL, error TEXT);
            CREATE TABLE IF NOT EXISTS segments(
              id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, locator REAL NOT NULL, snippet TEXT, vector BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS segments_file ON segments(file_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS keywords USING fts5(
              text, file_id UNINDEXED, locator UNINDEXED, kind UNINDEXED, tokenize='unicode61 remove_diacritics 2');
            """)
        try migrateSegmentIDs()
        try setMeta("schema", "\(Self.schemaVersion)")
        try setMeta("model", "\(EmbeddingModelFiles.repository)@\(EmbeddingModelFiles.revision)")
    }

    // MARK: - Damage

    private func isDamage(_ code: Int32) -> Bool {
        let primary = code & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Notes a failed SQLite call; reports damage once.
    private func failed(_ code: Int32) {
        guard isDamage(code), !damageReported else { return }
        damageReported = true
        onDamage?()
    }

    /// A full check of the file on a second, read-only connection (so indexing and search carry on meanwhile).
    /// True when SQLite finds nothing wrong.
    public func checkIntegrity() -> Bool {
        var check: OpaquePointer?
        guard sqlite3_open_v2(url.path, &check, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(check); return false }
        defer { sqlite3_close(check) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(check, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return !isDamage(sqlite3_errcode(check))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let first = sqlite3_column_text(statement, 0) else {
            return !isDamage(sqlite3_errcode(check))
        }
        return String(cString: first) == "ok"
    }

    /// Replaces a damaged index with an empty one, in place: the damaged file is kept beside it as
    /// `index.damaged.sqlite` (only the latest), and everyone reading this Catalog reloads.
    public func recover() throws {
        lock.lock(); defer { lock.unlock() }
        try moveAsideAndReopen()
        removedLogStart += removedLog.count
        removedLog.removeAll()
        pendingRemovals.removeAll()
        resetCount += 1
        generation += 1
        damageReported = false
    }

    private func moveAsideAndReopen() throws {
        sqlite3_close_v2(db)
        db = nil
        let fm = FileManager.default
        let aside = url.deletingPathExtension().appendingPathExtension("damaged.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + suffix), to = URL(fileURLWithPath: aside.path + suffix)
            try? fm.removeItem(at: to)
            if fm.fileExists(atPath: from.path) {
                do { try fm.moveItem(at: from, to: to) } catch { try? fm.removeItem(at: from) }
            }
        }
        try open()
    }

    /// Segment ids must never be reused, or search's "load rows after the last id I have" would miss new rows that
    /// took a deleted row's id. Indexes made before AUTOINCREMENT get their table rebuilt with it, ids kept.
    private func migrateSegmentIDs() throws {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'segments'")
        let sql = sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
        sqlite3_finalize(statement)   // before the rebuild, or SQLite says the table is locked
        guard let sql, !sql.contains("AUTOINCREMENT") else { return }
        try exec("""
            PRAGMA foreign_keys=OFF;
            BEGIN IMMEDIATE;
            CREATE TABLE segments_new(
              id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, locator REAL NOT NULL, snippet TEXT, vector BLOB NOT NULL);
            INSERT INTO segments_new(id, file_id, kind, locator, snippet, vector)
              SELECT id, file_id, kind, locator, snippet, vector FROM segments;
            DROP TABLE segments;
            ALTER TABLE segments_new RENAME TO segments;
            CREATE INDEX IF NOT EXISTS segments_file ON segments(file_id);
            COMMIT;
            PRAGMA foreign_keys=ON;
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writes

    /// Replaces everything stored for `path` with the given segments and keywords (or records why it couldn't be read).
    public func replaceFile(path: String, kind: String, size: Int64, mtime: Double, segments: [SegmentRow],
                            keywords: [KeywordRow], error: String?) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            if let old = try fileID(path: path) { try deleteFile(id: old) }
            let insertFile = try prepare("""
                INSERT INTO files(path, name, kind, size, mtime, indexed_at, error) VALUES(?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(insertFile) }
            bind(insertFile, 1, path)
            bind(insertFile, 2, (path as NSString).lastPathComponent)
            bind(insertFile, 3, kind)
            sqlite3_bind_int64(insertFile, 4, size)
            sqlite3_bind_double(insertFile, 5, mtime)
            sqlite3_bind_double(insertFile, 6, Date().timeIntervalSince1970)
            bind(insertFile, 7, error)
            try step(insertFile)
            let fileID = sqlite3_last_insert_rowid(db)

            let insertSegment = try prepare("INSERT INTO segments(file_id, kind, locator, snippet, vector) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(insertSegment) }
            for segment in segments {
                sqlite3_reset(insertSegment)
                sqlite3_bind_int64(insertSegment, 1, fileID)
                bind(insertSegment, 2, segment.kind.rawValue)
                sqlite3_bind_double(insertSegment, 3, segment.locator)
                bind(insertSegment, 4, segment.snippet)
                segment.vector.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(insertSegment, 5, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
                try step(insertSegment)
            }

            // Each file's keyword rows get rowids in a block of their own (file id << 20), so deleting a file's rows
            // is a rowid range instead of a scan of the whole table.
            let insertKeyword = try prepare("INSERT INTO keywords(rowid, text, file_id, locator, kind) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(insertKeyword) }
            // The file name is searchable by its words too ("invoice_2024-03" → invoice 2024 03).
            let nameWords = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            let rows = ([KeywordRow(text: nameWords, locator: -1, kind: .text)] + keywords).filter { !$0.text.isEmpty }
            for (n, keyword) in rows.prefix(1 << 20).enumerated() {
                sqlite3_reset(insertKeyword)
                sqlite3_bind_int64(insertKeyword, 1, fileID << 20 | Int64(n))
                bind(insertKeyword, 2, keyword.text)
                sqlite3_bind_int64(insertKeyword, 3, fileID)
                sqlite3_bind_double(insertKeyword, 4, keyword.locator)
                bind(insertKeyword, 5, keyword.kind.rawValue)
                try step(insertKeyword)
            }
            try exec("COMMIT")
            commitRemovals()
        } catch {
            try? exec("ROLLBACK")
            pendingRemovals.removeAll()
            throw error
        }
    }

    public func removeFiles(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            for path in paths {
                if let id = try fileID(path: path) { try deleteFile(id: id) }
            }
            try exec("COMMIT")
            commitRemovals()
        } catch {
            try? exec("ROLLBACK")
            pendingRemovals.removeAll()
            throw error
        }
    }

    /// Removes every file under `folder` (a folder taken out of the search).
    public func removeFiles(under folder: String) throws {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let paths = try allPaths().filter { $0.hasPrefix(prefix) }
        try removeFiles(paths: paths)
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM keywords; DELETE FROM segments; DELETE FROM files;")
        removedLogStart += removedLog.count
        removedLog.removeAll()
        resetCount += 1
        generation += 1
    }

    /// After a commit: the deleted segments join the log, and readers see a new generation.
    private func commitRemovals() {
        removedLog += pendingRemovals
        pendingRemovals.removeAll()
        // A long log only costs memory: past a million ids, readers reload in full once instead.
        if removedLog.count > 1_000_000 {
            removedLogStart += removedLog.count
            removedLog.removeAll()
            resetCount += 1
        }
        generation += 1
    }

    private func deleteFile(id: Int64) throws {
        let segments = try prepare("SELECT id FROM segments WHERE file_id = ?")
        sqlite3_bind_int64(segments, 1, id)
        while sqlite3_step(segments) == SQLITE_ROW { pendingRemovals.append(sqlite3_column_int64(segments, 0)) }
        sqlite3_finalize(segments)
        let statement = try prepare("DELETE FROM keywords WHERE rowid BETWEEN ? AND ?")
        sqlite3_bind_int64(statement, 1, id << 20)
        sqlite3_bind_int64(statement, 2, id << 20 | (1 << 20 - 1))
        try step(statement)
        sqlite3_finalize(statement)
        let files = try prepare("DELETE FROM files WHERE id = ?")   // segments go with it (ON DELETE CASCADE)
        sqlite3_bind_int64(files, 1, id)
        try step(files)
        sqlite3_finalize(files)
    }

    // MARK: - Reads

    public func fileStates() throws -> [String: FileState] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT id, path, size, mtime FROM files")
        defer { sqlite3_finalize(statement) }
        var out: [String: FileState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            out[text(statement, 1) ?? ""] = FileState(id: sqlite3_column_int64(statement, 0),
                                                      size: sqlite3_column_int64(statement, 2),
                                                      mtime: sqlite3_column_double(statement, 3))
        }
        endOfRows(statement)
        return out
    }

    public func allPaths() throws -> [String] { try Array(fileStates().keys) }

    /// The vectors of segments with ids above `id` (all of them for 0), in id order, in one contiguous row-major
    /// matrix, with each row's segment and file.
    public func loadVectors(after id: Int64 = 0) throws -> (segments: [Int64], files: [Int64], matrix: [Float]) {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT id, file_id, vector FROM segments WHERE id > ? ORDER BY id")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        var segments: [Int64] = [], files: [Int64] = [], matrix: [Float] = []
        let dimension = EmbeddingService.dimension
        while sqlite3_step(statement) == SQLITE_ROW {
            let bytes = Int(sqlite3_column_bytes(statement, 2))
            guard bytes == dimension * 4, let blob = sqlite3_column_blob(statement, 2) else { continue }
            segments.append(sqlite3_column_int64(statement, 0))
            files.append(sqlite3_column_int64(statement, 1))
            matrix.append(contentsOf: UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension))
        }
        endOfRows(statement)
        return (segments, files, matrix)
    }

    /// The exact vectors of these segments (search rescores its best candidates with them when it holds 8-bit ones).
    public func vectors(ids: [Int64]) throws -> [Int64: [Float]] {
        guard !ids.isEmpty else { return [:] }
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT id, vector FROM segments WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
        defer { sqlite3_finalize(statement) }
        let dimension = EmbeddingService.dimension
        var out: [Int64: [Float]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard Int(sqlite3_column_bytes(statement, 1)) == dimension * 4, let blob = sqlite3_column_blob(statement, 1) else { continue }
            out[sqlite3_column_int64(statement, 0)] = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension))
        }
        endOfRows(statement)
        return out
    }

    /// Where a reader stands: the generation, the reset count, and the end of the removal log.
    public struct Position: Sendable, Equatable {
        public let generation: Int
        public let resetCount: Int
        public let removals: Int
    }

    public func position() -> Position {
        lock.lock(); defer { lock.unlock() }
        return Position(generation: generation, resetCount: resetCount, removals: removedLogStart + removedLog.count)
    }

    /// Segment ids deleted after removal number `after`, or nil when the log no longer reaches back that far (then
    /// the reader must reload in full).
    public func removedSegments(after: Int) -> [Int64]? {
        lock.lock(); defer { lock.unlock() }
        guard after >= removedLogStart else { return nil }
        return Array(removedLog[(after - removedLogStart)...])
    }

    public func segmentInfo(ids: [Int64]) throws -> [Int64: SegmentInfo] {
        guard !ids.isEmpty else { return [:] }
        lock.lock(); defer { lock.unlock() }
        let list = ids.map(String.init).joined(separator: ",")
        let statement = try prepare("""
            SELECT s.id, s.file_id, f.path, f.kind, s.kind, s.locator, s.snippet
            FROM segments s JOIN files f ON f.id = s.file_id WHERE s.id IN (\(list))
            """)
        defer { sqlite3_finalize(statement) }
        var out: [Int64: SegmentInfo] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let info = SegmentInfo(segmentID: sqlite3_column_int64(statement, 0), fileID: sqlite3_column_int64(statement, 1),
                                   path: text(statement, 2) ?? "", fileKind: text(statement, 3) ?? "",
                                   kind: SegmentKind(rawValue: text(statement, 4) ?? "") ?? .text,
                                   locator: sqlite3_column_double(statement, 5), snippet: text(statement, 6))
            out[info.segmentID] = info
        }
        return out
    }

    public struct KeywordHit: Sendable {
        public let fileID: Int64
        public let path: String
        public let fileKind: String
        public let locator: Double
        public let kind: SegmentKind
        public let rank: Double       // bm25: lower is better
        public let snippet: String
    }

    /// Files whose text or name holds all of `terms` (prefix matches), best first.
    public func keywordSearch(terms: [String], limit: Int = 60) throws -> [KeywordHit] {
        let cleaned = terms.map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }
        let match = cleaned.map { "\"\($0)\"*" }.joined(separator: " ")
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
            SELECT k.file_id, f.path, f.kind, k.locator, k.kind, bm25(keywords),
                   snippet(keywords, 0, '«', '»', '…', 12)
            FROM keywords k JOIN files f ON f.id = k.file_id
            WHERE keywords MATCH ? ORDER BY bm25(keywords) LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, match)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var out: [KeywordHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(KeywordHit(fileID: sqlite3_column_int64(statement, 0), path: text(statement, 1) ?? "",
                                  fileKind: text(statement, 2) ?? "", locator: sqlite3_column_double(statement, 3),
                                  kind: SegmentKind(rawValue: text(statement, 4) ?? "") ?? .text,
                                  rank: sqlite3_column_double(statement, 5), snippet: text(statement, 6) ?? ""))
        }
        return out
    }

    /// The text stored for one file, in order: its chunks, pages, picture text or transcript lines, each with where it
    /// is (a character offset, a page, a second). Ask quotes these to the answer model. The file-name row is left out.
    public func texts(path: String) throws -> [KeywordRow] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
            SELECT k.text, k.locator, k.kind FROM keywords k JOIN files f ON f.id = k.file_id
            WHERE f.path = ? AND k.locator >= 0 ORDER BY k.locator, k.rowid
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, path)
        var out: [KeywordRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(KeywordRow(text: text(statement, 0) ?? "", locator: sqlite3_column_double(statement, 1),
                                  kind: SegmentKind(rawValue: text(statement, 2) ?? "") ?? .text))
        }
        return out
    }

    /// What the index holds for one chosen folder (everything under it) or file.
    public func counts(under path: String) throws -> IndexCounts {
        lock.lock(); defer { lock.unlock() }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let statement = try prepare("""
            SELECT kind, COUNT(*), SUM(error IS NOT NULL) FROM files
            WHERE path = ? OR substr(path, 1, ?) = ? GROUP BY kind
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, path)
        sqlite3_bind_int(statement, 2, Int32(prefix.unicodeScalars.count))   // substr counts characters, not bytes
        bind(statement, 3, prefix)
        var counts = IndexCounts()
        while sqlite3_step(statement) == SQLITE_ROW {
            let n = Int(sqlite3_column_int64(statement, 1))
            counts.files += n
            counts.failed += Int(sqlite3_column_int64(statement, 2))
            counts.byKind[text(statement, 0) ?? "?"] = n
        }
        return counts
    }

    public func counts() throws -> IndexCounts {
        lock.lock(); defer { lock.unlock() }
        var counts = IndexCounts()
        let files = try prepare("SELECT kind, COUNT(*), SUM(error IS NOT NULL) FROM files GROUP BY kind")
        defer { sqlite3_finalize(files) }
        while sqlite3_step(files) == SQLITE_ROW {
            let n = Int(sqlite3_column_int64(files, 1))
            counts.files += n
            counts.failed += Int(sqlite3_column_int64(files, 2))
            counts.byKind[text(files, 0) ?? "?"] = n
        }
        let segments = try prepare("SELECT COUNT(*) FROM segments")
        defer { sqlite3_finalize(segments) }
        if sqlite3_step(segments) == SQLITE_ROW { counts.segments = Int(sqlite3_column_int64(segments, 0)) }
        return counts
    }

    // MARK: - Helpers

    private func fileID(path: String) throws -> Int64? {
        let statement = try prepare("SELECT id FROM files WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, path)
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    public func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let statement = try? prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        bind(statement, 2, value)
        try step(statement)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            failed(sqlite3_errcode(db))
            throw CatalogError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            failed(sqlite3_errcode(db))
            throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            failed(result)
            throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// After a `while sqlite3_step(...) == SQLITE_ROW` loop: reports damage if the rows stopped on an error.
    private func endOfRows(_ statement: OpaquePointer?) {
        let code = sqlite3_errcode(db)
        if code != SQLITE_OK && code != SQLITE_DONE && code != SQLITE_ROW { failed(code) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}
