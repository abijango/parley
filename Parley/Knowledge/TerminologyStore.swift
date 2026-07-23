import Foundation
import SQLite3

/// Glossary entries injected into summary prompts (writer + checker).
///
/// `scope` scopes a correction to one customer/filing context (e.g. "MAN Group").
/// Empty scope = global. Customer-scoped entries are only injected for matching
/// meetings so "Maya → Maia (platform)" does not leak to other customers, and
/// notes can clarify not to rename a person named Maya.
struct TerminologyEntry: Equatable, Identifiable, Codable, Sendable {
    let id: String
    var fromText: String
    var toText: String
    var notes: String
    var source: String
    /// Customer / filing scope key; empty = applies everywhere.
    var scope: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, fromText, toText, notes, source, scope, createdAt
    }

    init(id: String, fromText: String, toText: String, notes: String, source: String,
         scope: String = "", createdAt: Date) {
        self.id = id
        self.fromText = fromText
        self.toText = toText
        self.notes = notes
        self.source = source
        self.scope = scope
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fromText = try c.decode(String.self, forKey: .fromText)
        toText = try c.decode(String.self, forKey: .toText)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        source = try c.decode(String.self, forKey: .source)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// CRUD for the `terminology` table.
final class TerminologyStore: @unchecked Sendable {
    private let db: KnowledgeDatabase

    init(database: KnowledgeDatabase = .shared) {
        self.db = database
    }

    func all() -> [TerminologyEntry] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite,
                "SELECT id, from_text, to_text, notes, source, created_at, scope FROM terminology ORDER BY from_text COLLATE NOCASE;",
                -1, &stmt, nil) == SQLITE_OK else { return [] }
            var rows: [TerminologyEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(row(stmt))
            }
            return rows
        }
    }

    /// Global entries plus those matching `scope` (case-insensitive).
    func entries(forScope scope: String?) -> [TerminologyEntry] {
        let key = (scope ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all().filter { entry in
            let s = entry.scope.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            guard !key.isEmpty else { return false }
            return s.lowercased() == key
        }
    }

    func insert(from fromText: String, to toText: String, notes: String = "",
                source: String, scope: String = "") -> TerminologyEntry {
        let entry = TerminologyEntry(
            id: UUID().uuidString,
            fromText: fromText.trimmingCharacters(in: .whitespacesAndNewlines),
            toText: toText.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            source: source,
            scope: scope.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite,
                "INSERT INTO terminology(id, from_text, to_text, notes, source, created_at, scope) VALUES (?, ?, ?, ?, ?, ?, ?);",
                -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, entry.id)
            KnowledgeSQL.bind(stmt, 2, entry.fromText)
            KnowledgeSQL.bind(stmt, 3, entry.toText)
            KnowledgeSQL.bind(stmt, 4, entry.notes)
            KnowledgeSQL.bind(stmt, 5, entry.source)
            sqlite3_bind_double(stmt, 6, entry.createdAt.timeIntervalSince1970)
            KnowledgeSQL.bind(stmt, 7, entry.scope)
            sqlite3_step(stmt)
        }
        return entry
    }

    func upsert(from fromText: String, to toText: String, notes: String = "",
                source: String, scope: String = "") {
        let fromKey = fromText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scopeKey = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = all().first(where: {
            $0.fromText.lowercased() == fromKey
                && $0.scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == scopeKey
        }) {
            update(id: existing.id, fromText: fromText, toText: toText, notes: notes, scope: scope)
        } else {
            _ = insert(from: fromText, to: toText, notes: notes, source: source, scope: scope)
        }
    }

    func update(id: String, fromText: String? = nil, toText: String? = nil,
                notes: String? = nil, scope: String? = nil) {
        guard var entry = all().first(where: { $0.id == id }) else { return }
        if let fromText { entry.fromText = fromText }
        if let toText { entry.toText = toText }
        if let notes { entry.notes = notes }
        if let scope { entry.scope = scope }
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite,
                "UPDATE terminology SET from_text = ?, to_text = ?, notes = ?, scope = ? WHERE id = ?;",
                -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, entry.fromText)
            KnowledgeSQL.bind(stmt, 2, entry.toText)
            KnowledgeSQL.bind(stmt, 3, entry.notes)
            KnowledgeSQL.bind(stmt, 4, entry.scope)
            KnowledgeSQL.bind(stmt, 5, id)
            sqlite3_step(stmt)
        }
    }

    func delete(id: String) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, "DELETE FROM terminology WHERE id = ?;", -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    /// Bullet list for prompt injection (optionally scoped to a customer).
    func promptBlock(forScope scope: String? = nil) -> String {
        let rows = entries(forScope: scope)
        guard !rows.isEmpty else { return "" }
        return rows.map { entry in
            var line = "- \"\(entry.fromText)\" → \"\(entry.toText)\""
            if !entry.scope.isEmpty {
                line += " [only for \(entry.scope)]"
            }
            if !entry.notes.isEmpty {
                line += " — \(entry.notes)"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Derive a customer scope key from a vault filing path.
    static func customerScope(fromFiling filing: String) -> String {
        let parts = filing
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare("Customers") == .orderedSame
            || $0.caseInsensitiveCompare("Customer") == .orderedSame }),
           i + 1 < parts.count {
            return parts[i + 1]
        }
        // Fall back to last path segment (often the customer folder).
        return parts.last ?? filing.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func row(_ stmt: OpaquePointer?) -> TerminologyEntry {
        let colCount = sqlite3_column_count(stmt)
        let scope: String
        if colCount > 6 {
            scope = KnowledgeSQL.text(stmt, 6)
        } else {
            scope = ""
        }
        return TerminologyEntry(
            id: KnowledgeSQL.text(stmt, 0),
            fromText: KnowledgeSQL.text(stmt, 1),
            toText: KnowledgeSQL.text(stmt, 2),
            notes: KnowledgeSQL.text(stmt, 3),
            source: KnowledgeSQL.text(stmt, 4),
            scope: scope,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        )
    }
}
