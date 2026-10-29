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

/// A canonical spelling plus the forms that should be corrected to it, e.g.
/// `LSEG` ← Elseg, L Seg, LSEC. Stored as one `terminology` row per form; a row whose
/// `from` equals its `to` records a canonical term with no known mishearings.
struct GlossaryTerm: Equatable, Sendable {
    var canonical: String
    var aliases: [String]
    var scope: String
    var notes: [String]

    static func group(_ entries: [TerminologyEntry]) -> [GlossaryTerm] {
        var order: [String] = []
        var byKey: [String: GlossaryTerm] = [:]
        for entry in entries {
            let canonical = entry.toText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            let scope = entry.scope.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = canonical.lowercased() + "\u{1F}" + scope.lowercased()
            var term = byKey[key] ?? GlossaryTerm(canonical: canonical, aliases: [], scope: scope, notes: [])
            if byKey[key] == nil { order.append(key) }
            let from = entry.fromText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !from.isEmpty, from.caseInsensitiveCompare(canonical) != .orderedSame,
               !term.aliases.contains(where: { $0.caseInsensitiveCompare(from) == .orderedSame }) {
                term.aliases.append(from)
            }
            let note = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, !term.notes.contains(note) { term.notes.append(note) }
            byKey[key] = term
        }
        return order.compactMap { byKey[$0] }
            .sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }
    }

    /// `Canonical: alias, alias` per line (a bare `Canonical` line is allowed).
    static func parse(_ text: String) -> [GlossaryTerm] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { return nil }
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            return GlossaryTerm(canonical: canonical, aliases: aliases, scope: "", notes: [])
        }
    }

    var pairs: [(from: String, to: String)] {
        let forms = aliases.filter { $0.caseInsensitiveCompare(canonical) != .orderedSame }
        if forms.isEmpty { return [(from: canonical, to: canonical)] }
        return forms.map { (from: $0, to: canonical) }
    }

    var editLine: String {
        aliases.isEmpty ? canonical : "\(canonical): \(aliases.joined(separator: ", "))"
    }

    var promptLine: String {
        var line = "- \(canonical)"
        if !aliases.isEmpty { line += " (also heard as: \(aliases.joined(separator: ", ")))" }
        if !scope.isEmpty { line += " [only for \(scope)]" }
        if !notes.isEmpty { line += " — \(notes.joined(separator: "; "))" }
        return line
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

    /// Entries grouped by canonical spelling: each canonical term with the misheard or
    /// alternative forms that should be corrected to it.
    func glossary(forScope scope: String? = nil) -> [GlossaryTerm] {
        GlossaryTerm.group(entries(forScope: scope))
    }

    /// One line per canonical term for `{{glossary}}` / prompt injection.
    func promptBlock(forScope scope: String? = nil) -> String {
        glossary(forScope: scope).map(\.promptLine).joined(separator: "\n")
    }

    /// Global (unscoped) glossary as editable text, `Canonical: alias, alias` per line.
    func globalGlossaryText() -> String {
        GlossaryTerm.group(all().filter { $0.scope.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(\.editLine).joined(separator: "\n")
    }

    /// Replace the global glossary from editor text. Customer-scoped corrections are
    /// untouched; rows that survive the edit keep their notes and source.
    func replaceGlobalGlossary(with text: String) {
        let desired = GlossaryTerm.parse(text).flatMap(\.pairs)
        let existing = all().filter { $0.scope.trimmingCharacters(in: .whitespaces).isEmpty }
        func key(_ from: String, _ to: String) -> String { from.lowercased() + "\u{1F}" + to.lowercased() }
        let desiredKeys = Set(desired.map { key($0.from, $0.to) })
        let existingKeys = Set(existing.map { key($0.fromText, $0.toText) })
        for entry in existing where !desiredKeys.contains(key(entry.fromText, entry.toText)) {
            delete(id: entry.id)
        }
        var inserted = Set<String>()
        for pair in desired where !existingKeys.contains(key(pair.from, pair.to)) {
            guard inserted.insert(key(pair.from, pair.to)).inserted else { continue }
            _ = insert(from: pair.from, to: pair.to, source: "glossary")
        }
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
