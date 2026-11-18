import Foundation
import CSQLite

enum IndexError: LocalizedError {
    case sqlite(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return L("SQLite hatası: %@", message)
        case .cancelled: return L("İşlem iptal edildi")
        }
    }
}

/// Thin, synchronous SQLite wrapper used only by `IndexStore` (single queue).
final class IndexDatabase {
    private var handle: OpaquePointer?
    private var upsertStatement: OpaquePointer?
    private var deleteStatement: OpaquePointer?
    private let path: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        self.path = path
    }

    deinit {
        sqlite3_finalize(upsertStatement)
        sqlite3_finalize(deleteStatement)
        sqlite3_close(handle)
    }

    // MARK: - Setup

    func open() throws {
        let status = path.withCString { sqlite3_open($0, &handle) }
        _ = status
        guard status == SQLITE_OK else { throw lastError() }
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA temp_store=MEMORY;
            PRAGMA cache_size=-20000;
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                is_dir INTEGER NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL,
                ctime REAL
            );
            CREATE INDEX IF NOT EXISTS idx_entries_parent ON entries(parent_id);
            CREATE INDEX IF NOT EXISTS idx_entries_path ON entries(path);
            CREATE TABLE IF NOT EXISTS roots (
                path TEXT PRIMARY KEY,
                kind TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)

        upsertStatement = try prepare("""
            INSERT INTO entries (id, parent_id, name, path, is_dir, size, mtime, ctime)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                id=excluded.id, parent_id=excluded.parent_id, name=excluded.name,
                is_dir=excluded.is_dir, size=excluded.size,
                mtime=excluded.mtime, ctime=excluded.ctime
            """)
        deleteStatement = try prepare("DELETE FROM entries WHERE path = ? OR path LIKE ? ESCAPE '\\'")
    }

    // MARK: - Raw helpers

    private func lastError() -> IndexError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "bilinmeyen hata"
        return .sqlite(message)
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sql.withCString { sqlite3_exec(handle, $0, nil, nil, &errorMessage) }
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "bilinmeyen hata"
            sqlite3_free(errorMessage)
            throw IndexError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sql.withCString { sqlite3_prepare_v2(handle, $0, -1, &statement, nil) }
        guard status == SQLITE_OK, let statement else { throw lastError() }
        return statement
    }

    private func bind(_ text: String, _ index: Int32, _ statement: OpaquePointer) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func step(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw lastError() }
    }

    // MARK: - Transactions

    func beginTransaction() throws { try exec("BEGIN IMMEDIATE") }
    func commit() throws { try exec("COMMIT") }
    func rollback() { try? exec("ROLLBACK") }

    // MARK: - Entries

    func upsert(_ entry: IndexEntry) throws {
        guard let statement = upsertStatement else { return }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, Int64(bitPattern: entry.id))
        sqlite3_bind_int64(statement, 2, Int64(bitPattern: entry.parentID))
        bind(entry.name, 3, statement)
        bind(entry.path, 4, statement)
        sqlite3_bind_int(statement, 5, entry.isDirectory ? 1 : 0)
        sqlite3_bind_int64(statement, 6, entry.size)
        if let date = entry.modifiedAt {
            sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        if let date = entry.createdAt {
            sqlite3_bind_double(statement, 8, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        try step(statement)
    }

    func deleteSubtree(path: String) throws {
        guard let statement = deleteStatement else { return }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(path, 1, statement)
        bind(Self.escapeLike(path) + "/%", 2, statement)
        try step(statement)
    }

    func deleteAll() throws { try exec("DELETE FROM entries") }

    private static func escapeLike(_ value: String) -> String {
        var result = ""
        for ch in value {
            if ch == "\\" || ch == "%" || ch == "_" { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    func loadAllEntries() throws -> [IndexEntry] {
        let statement = try prepare("SELECT id, parent_id, name, path, is_dir, size, mtime, ctime FROM entries")
        defer { sqlite3_finalize(statement) }
        var entries: [IndexEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 2),
                  let pathPointer = sqlite3_column_text(statement, 3) else { continue }
            let modified = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let created = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            entries.append(IndexEntry(
                id: UInt64(bitPattern: sqlite3_column_int64(statement, 0)),
                parentID: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                name: String(cString: namePointer),
                path: String(cString: pathPointer),
                isDirectory: sqlite3_column_int(statement, 4) != 0,
                size: sqlite3_column_int64(statement, 5),
                modifiedAt: modified,
                createdAt: created
            ))
        }
        return entries
    }

    func count() -> Int {
        guard let statement = try? prepare("SELECT count(*) FROM entries") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    // MARK: - Roots & metadata

    func loadRoots() -> [IndexRoot] {
        guard let statement = try? prepare("SELECT path, kind FROM roots") else { return [] }
        defer { sqlite3_finalize(statement) }
        var roots: [IndexRoot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            let kind = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
            roots.append(IndexRoot(path: String(cString: pointer), kind: VolumeKind(rawValue: kind) ?? .unknown))
        }
        return roots
    }

    func setRoots(_ roots: [IndexRoot]) throws {
        try exec("DELETE FROM roots")
        let statement = try prepare("INSERT OR REPLACE INTO roots (path, kind) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        for root in roots {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(root.path, 1, statement)
            bind(root.kind.rawValue, 2, statement)
            try step(statement)
        }
    }

    func meta(_ key: String) -> String? {
        guard let statement = try? prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: pointer)
    }

    func setMeta(_ key: String, value: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, 1, statement)
        bind(value, 2, statement)
        try step(statement)
    }
}
