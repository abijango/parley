import Foundation
import SQLite3

/// App-owned SQLite store for Summary v2 run history, terminology, and people (rolodex replacement).
final class KnowledgeDatabase: @unchecked Sendable {
    static let shared = KnowledgeDatabase()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let path: URL

    private init(path: URL? = nil) {
        let dir = AppPaths.supportDirectory
        AppPaths.ensureDirectory(dir)
        self.path = path ?? dir.appendingPathComponent("Parley.sqlite")
        openAndMigrate()
    }

    /// Test / alternate-path opener.
    static func openTemporary() -> KnowledgeDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-knowledge-\(UUID().uuidString).sqlite")
        return KnowledgeDatabase(path: url)
    }

    private init(path: URL) {
        self.path = path
        openAndMigrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var fileURL: URL { path }

    func withDB<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { fatalError("KnowledgeDatabase not open") }
        return try body(db)
    }

    private func openAndMigrate() {
        if sqlite3_open(path.path, &db) != SQLITE_OK {
            AppLog.log("KnowledgeDB: failed to open \(path.path)", category: "knowledge")
            db = nil
            return
        }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        migrate()
    }

    private func migrate() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS schema_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS terminology (
            id TEXT PRIMARY KEY,
            from_text TEXT NOT NULL,
            to_text TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL,
            created_at REAL NOT NULL,
            scope TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS summary_runs (
            id TEXT PRIMARY KEY,
            transcript_id TEXT NOT NULL,
            transcript_path TEXT NOT NULL,
            created_at REAL NOT NULL,
            writer_backend TEXT NOT NULL,
            checker_backend TEXT NOT NULL,
            draft_markdown TEXT NOT NULL,
            checker_raw TEXT NOT NULL DEFAULT '',
            checker_parse_ok INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_summary_runs_transcript
            ON summary_runs(transcript_id, created_at DESC);
        CREATE TABLE IF NOT EXISTS summary_hunks (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            sort_index INTEGER NOT NULL,
            op TEXT NOT NULL,
            target TEXT NOT NULL DEFAULT '',
            after_anchor TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL DEFAULT '',
            reason TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending',
            override_text TEXT,
            FOREIGN KEY(run_id) REFERENCES summary_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_summary_hunks_run ON summary_hunks(run_id, sort_index);
        CREATE TABLE IF NOT EXISTS people (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            company TEXT,
            side TEXT NOT NULL,
            title TEXT,
            linkedin TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_people_name ON people(name);
        CREATE TABLE IF NOT EXISTS person_aliases (
            person_id TEXT NOT NULL,
            alias TEXT NOT NULL,
            PRIMARY KEY (person_id, alias),
            FOREIGN KEY(person_id) REFERENCES people(id) ON DELETE CASCADE
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            AppLog.log("KnowledgeDB: migrate error — \(String(cString: sqlite3_errmsg(db)))", category: "knowledge")
        }
        // Existing installs created terminology without `scope` — add it if missing.
        _ = sqlite3_exec(db, "ALTER TABLE terminology ADD COLUMN scope TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        setMeta(key: "schema_version", value: "2")
    }

    func setMeta(key: String, value: String) {
        withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO schema_meta(key, value) VALUES (?, ?);", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func meta(key: String) -> String? {
        withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM schema_meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }
    }
}

/// SQLite binder helper — `SQLITE_TRANSIENT` copies the string.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum KnowledgeSQL {
    static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    static func optionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    static func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
