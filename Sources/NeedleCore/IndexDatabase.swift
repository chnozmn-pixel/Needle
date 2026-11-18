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
                ctime REAL,
                tags TEXT NOT NULL DEFAULT '',
                comment TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_entries_parent ON entries(parent_id);
            CREATE INDEX IF NOT EXISTS idx_entries_path ON entries(path);
            CREATE TABLE IF NOT EXISTS roots (
                path TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                excluded TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS file_lists (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                imported_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS list_entries (
                list_id TEXT NOT NULL,
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                is_dir INTEGER NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL,
                ctime REAL,
                tags TEXT NOT NULL DEFAULT '',
                comment TEXT,
                FOREIGN KEY(list_id) REFERENCES file_lists(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_list_entries_path ON list_entries(path);
            CREATE TABLE IF NOT EXISTS journal (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL,
                action TEXT NOT NULL,
                at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_journal_at ON journal(at DESC);
            """)

        // Existing databases created before metadata, root settings and file
        // lists gain the new columns in place so no migration step is needed.
        if !columnExists(table: "entries", column: "tags") {
            try exec("ALTER TABLE entries ADD COLUMN tags TEXT NOT NULL DEFAULT ''")
        }
        if !columnExists(table: "entries", column: "comment") {
            try exec("ALTER TABLE entries ADD COLUMN comment TEXT")
        }
        if !columnExists(table: "roots", column: "is_enabled") {
            try exec("ALTER TABLE roots ADD COLUMN is_enabled INTEGER NOT NULL DEFAULT 1")
        }
        if !columnExists(table: "roots", column: "excluded") {
            try exec("ALTER TABLE roots ADD COLUMN excluded TEXT NOT NULL DEFAULT ''")
        }

        upsertStatement = try prepare("""
            INSERT INTO entries (id, parent_id, name, path, is_dir, size, mtime, ctime, tags, comment)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                id=excluded.id, parent_id=excluded.parent_id, name=excluded.name,
                is_dir=excluded.is_dir, size=excluded.size,
                mtime=excluded.mtime, ctime=excluded.ctime,
                tags=excluded.tags, comment=excluded.comment
            """)
        deleteStatement = try prepare("DELETE FROM entries WHERE path = ? OR path LIKE ? ESCAPE '\\'")
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let statement = try? prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: pointer) == column { return true }
        }
        return false
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

    private func exec(_ sql: String, bindings: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            bind(value, Int32(offset + 1), statement)
        }
        try step(statement)
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

    private func encodeStrings(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private func decodeStrings(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return values
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
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
        bind(encodeStrings(entry.tags), 9, statement)
        if let comment = entry.comment {
            bind(comment, 10, statement)
        } else {
            sqlite3_bind_null(statement, 10)
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

    /// Clears locally scanned entries only. Imported EFU lists survive rescans.
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
        // Local scan entries win when an EFU list repeats the same path.
        let statement = try prepare("""
            SELECT * FROM (
                SELECT id, parent_id, name, path, is_dir, size, mtime, ctime, tags, comment, 0 AS priority
                FROM entries
                UNION ALL
                SELECT id, parent_id, name, path, is_dir, size, mtime, ctime, tags, comment, 1 AS priority
                FROM list_entries
            ) ORDER BY path, priority
            """)
        defer { sqlite3_finalize(statement) }
        var entries: [IndexEntry] = []
        var seenPaths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = optionalText(statement, 2), let path = optionalText(statement, 3),
                  seenPaths.insert(path).inserted else { continue }
            let modified = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let created = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            entries.append(IndexEntry(
                id: UInt64(bitPattern: sqlite3_column_int64(statement, 0)),
                parentID: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                name: name,
                path: path,
                isDirectory: sqlite3_column_int(statement, 4) != 0,
                size: sqlite3_column_int64(statement, 5),
                modifiedAt: modified,
                createdAt: created,
                tags: decodeStrings(optionalText(statement, 8)),
                comment: optionalText(statement, 9)
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
        guard let statement = try? prepare("SELECT path, kind, is_enabled, excluded FROM roots") else { return [] }
        defer { sqlite3_finalize(statement) }
        var roots: [IndexRoot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = optionalText(statement, 0) else { continue }
            let kind = optionalText(statement, 1) ?? "unknown"
            roots.append(IndexRoot(
                path: path,
                kind: VolumeKind(rawValue: kind) ?? .unknown,
                isEnabled: sqlite3_column_int(statement, 2) != 0,
                excludedPaths: decodeStrings(optionalText(statement, 3))
            ))
        }
        return roots
    }

    func setRoots(_ roots: [IndexRoot]) throws {
        try exec("DELETE FROM roots")
        let statement = try prepare("""
            INSERT OR REPLACE INTO roots (path, kind, is_enabled, excluded) VALUES (?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        for root in roots {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(root.path, 1, statement)
            bind(root.kind.rawValue, 2, statement)
            sqlite3_bind_int(statement, 3, root.isEnabled ? 1 : 0)
            bind(encodeStrings(root.excludedPaths), 4, statement)
            try step(statement)
        }
    }

    // MARK: - EFU file lists

    func addFileList(id: String, name: String, items: [FileListItem]) throws {
        try exec("DELETE FROM file_lists WHERE id = ?", bindings: [id])
        try exec("DELETE FROM list_entries WHERE list_id = ?", bindings: [id])

        let listStatement = try prepare("INSERT INTO file_lists (id, name, imported_at) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(listStatement) }
        bind(id, 1, listStatement)
        bind(name, 2, listStatement)
        sqlite3_bind_double(listStatement, 3, Date().timeIntervalSince1970)
        try step(listStatement)

        let entryStatement = try prepare("""
            INSERT OR REPLACE INTO list_entries
            (list_id, id, parent_id, name, path, is_dir, size, mtime, ctime, tags, comment)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(entryStatement) }
        for item in items {
            let entry = IndexEntry.make(
                path: item.path,
                isDirectory: item.isDirectory,
                size: item.size,
                modifiedAt: item.modifiedAt,
                createdAt: item.createdAt,
                tags: item.tags,
                comment: item.comment
            )
            sqlite3_reset(entryStatement)
            sqlite3_clear_bindings(entryStatement)
            bind(id, 1, entryStatement)
            sqlite3_bind_int64(entryStatement, 2, Int64(bitPattern: entry.id))
            sqlite3_bind_int64(entryStatement, 3, Int64(bitPattern: entry.parentID))
            bind(entry.name, 4, entryStatement)
            bind(entry.path, 5, entryStatement)
            sqlite3_bind_int(entryStatement, 6, entry.isDirectory ? 1 : 0)
            sqlite3_bind_int64(entryStatement, 7, entry.size)
            if let date = entry.modifiedAt {
                sqlite3_bind_double(entryStatement, 8, date.timeIntervalSince1970)
            } else { sqlite3_bind_null(entryStatement, 8) }
            if let date = entry.createdAt {
                sqlite3_bind_double(entryStatement, 9, date.timeIntervalSince1970)
            } else { sqlite3_bind_null(entryStatement, 9) }
            bind(encodeStrings(entry.tags), 10, entryStatement)
            if let comment = entry.comment { bind(comment, 11, entryStatement) }
            else { sqlite3_bind_null(entryStatement, 11) }
            try step(entryStatement)
        }
    }

    func removeFileList(id: String) throws {
        try exec("DELETE FROM list_entries WHERE list_id = ?", bindings: [id])
        try exec("DELETE FROM file_lists WHERE id = ?", bindings: [id])
    }

    func loadFileLists() -> [FileListInfo] {
        guard let statement = try? prepare("""
            SELECT f.id, f.name, f.imported_at, count(e.path)
            FROM file_lists f LEFT JOIN list_entries e ON e.list_id = f.id
            GROUP BY f.id, f.name, f.imported_at
            ORDER BY f.imported_at DESC
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [FileListInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = optionalText(statement, 0), let name = optionalText(statement, 1) else { continue }
            result.append(FileListInfo(
                id: id,
                name: name,
                importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                count: Int(sqlite3_column_int64(statement, 3))
            ))
        }
        return result
    }

    // MARK: - Index journal

    func appendJournal(path: String, action: String) {
        guard let statement = try? prepare("INSERT INTO journal (path, action, at) VALUES (?, ?, ?)") else { return }
        defer { sqlite3_finalize(statement) }
        bind(path, 1, statement)
        bind(action, 2, statement)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        try? step(statement)
        // Keep the journal bounded on long-running installations.
        try? exec("""
            DELETE FROM journal WHERE id NOT IN (
                SELECT id FROM journal ORDER BY id DESC LIMIT 1000
            )
            """)
    }

    func loadJournal(limit: Int) -> [IndexJournalEntry] {
        guard let statement = try? prepare("""
            SELECT id, path, action, at FROM journal ORDER BY id DESC LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var result: [IndexJournalEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = optionalText(statement, 1), let action = optionalText(statement, 2) else { continue }
            result.append(IndexJournalEntry(
                id: Int64(sqlite3_column_int64(statement, 0)),
                path: path,
                action: action,
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return result
    }

    func clearJournal() throws { try exec("DELETE FROM journal") }

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
