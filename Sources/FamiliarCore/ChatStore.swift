import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ChatSummary: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let title: String
    public let updated: Date
    /// The chosen folder or file the chat searches in; nil: everything.
    public let scope: String?
}

public struct ChatTurn: Sendable, Identifiable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: Int64
    public let role: Role
    public let content: String
    /// The passages an answer quoted (its [n] point here); empty for a question.
    public let passages: [Passage]
    public let created: Date
}

/// Saved chats, in their own file (chats.sqlite) beside the index: rebuilding or replacing a damaged index never
/// takes your conversations with it. Each answer keeps the passages it quoted, so its [1] [2] still open the right
/// page or moment later.
public final class ChatStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = AppPaths.chats) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CatalogError.sqlite("can't open the chats file")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS chats(
              id INTEGER PRIMARY KEY, title TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, scope TEXT);
            CREATE TABLE IF NOT EXISTS turns(
              id INTEGER PRIMARY KEY, chat_id INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
              role TEXT NOT NULL, content TEXT NOT NULL, passages TEXT, created REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS turns_chat ON turns(chat_id);
            """)
    }

    deinit { sqlite3_close(db) }

    /// Newest first.
    public func chats() -> [ChatSummary] {
        lock.lock(); defer { lock.unlock() }
        var out: [ChatSummary] = []
        query("SELECT id, title, updated, scope FROM chats ORDER BY updated DESC") { s in
            out.append(ChatSummary(id: sqlite3_column_int64(s, 0), title: Self.text(s, 1) ?? "", updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                                   scope: Self.text(s, 3)))
        }
        return out
    }

    public func create(title: String, scope: String?) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        run("INSERT INTO chats(title, created, updated, scope) VALUES(?,?,?,?)", [.text(title), .real(now), .real(now), .text(scope)])
        return sqlite3_last_insert_rowid(db)
    }

    public func turns(chat: Int64) -> [ChatTurn] {
        lock.lock(); defer { lock.unlock() }
        var out: [ChatTurn] = []
        query("SELECT id, role, content, passages, created FROM turns WHERE chat_id = ? ORDER BY id", [.int(chat)]) { s in
            let stored = Self.text(s, 3).flatMap { try? JSONDecoder().decode([StoredPassage].self, from: Data($0.utf8)) } ?? []
            out.append(ChatTurn(id: sqlite3_column_int64(s, 0), role: ChatTurn.Role(rawValue: Self.text(s, 1) ?? "") ?? .user,
                                content: Self.text(s, 2) ?? "", passages: stored.map(\.passage),
                                created: Date(timeIntervalSince1970: sqlite3_column_double(s, 4))))
        }
        return out
    }

    @discardableResult
    public func append(chat: Int64, role: ChatTurn.Role, content: String, passages: [Passage] = []) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let json = passages.isEmpty ? nil : (try? JSONEncoder().encode(passages.map(StoredPassage.init))).map { String(decoding: $0, as: UTF8.self) }
        run("INSERT INTO turns(chat_id, role, content, passages, created) VALUES(?,?,?,?,?)",
            [.int(chat), .text(role.rawValue), .text(content), .text(json), .real(now)])
        let id = sqlite3_last_insert_rowid(db)
        run("UPDATE chats SET updated = ? WHERE id = ?", [.real(now), .int(chat)])
        return id
    }

    public func rename(chat: Int64, title: String) {
        lock.lock(); defer { lock.unlock() }
        run("UPDATE chats SET title = ? WHERE id = ?", [.text(title), .int(chat)])
    }

    public func setScope(chat: Int64, scope: String?) {
        lock.lock(); defer { lock.unlock() }
        run("UPDATE chats SET scope = ? WHERE id = ?", [.text(scope), .int(chat)])
    }

    public func delete(chat: Int64) {
        lock.lock(); defer { lock.unlock() }
        run("DELETE FROM chats WHERE id = ?", [.int(chat)])
    }

    // MARK: - SQLite

    private enum Value { case int(Int64), real(Double), text(String?) }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw CatalogError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): if let v { sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(statement, index) }
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) {
        let statement = prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) != SQLITE_DONE {
            LogFile.append("\(ISO8601DateFormatter().string(from: Date())) chats: \(String(cString: sqlite3_errmsg(db)))\n", to: "app.log")
        }
    }

    private func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer?) -> Void) {
        let statement = prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

/// A passage as saved with its answer: enough to show it and to open its file at the right place again.
private struct StoredPassage: Codable {
    let number: Int
    let label: String
    let text: String
    let path: String
    let fileKind: String
    let segmentKind: String
    let locator: Double

    init(_ p: Passage) {
        number = p.number; label = p.label; text = p.text
        path = p.source.path; fileKind = p.source.fileKind.rawValue
        segmentKind = p.source.segmentKind.rawValue; locator = p.source.locator
    }

    var passage: Passage {
        Passage(number: number, label: label, text: text,
                source: SearchResult(path: path, fileKind: FileKind(rawValue: fileKind) ?? .text, score: 0,
                                     segmentKind: SegmentKind(rawValue: segmentKind) ?? .text, locator: locator,
                                     snippet: nil, exactMatch: false))
    }
}
