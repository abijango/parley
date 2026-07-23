import Foundation
import SQLite3

/// Person row in the knowledge DB (rolodex replacement).
struct PersonRecord: Equatable, Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var company: String?
    var side: Side
    var title: String?
    var linkedin: String?
    var aliases: [String]
    let createdAt: Date
    var updatedAt: Date

    func asContact() -> Contact {
        Contact(name: name, company: company, side: side, title: title, linkedin: linkedin, aliases: aliases)
    }
}

/// CRUD for `people` + `person_aliases`.
final class PeopleStore: @unchecked Sendable {
    private let db: KnowledgeDatabase

    init(database: KnowledgeDatabase = .shared) {
        self.db = database
    }

    func isEmpty() -> Bool {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, "SELECT COUNT(*) FROM people;", -1, &stmt, nil) == SQLITE_OK else {
                return true
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
            return sqlite3_column_int(stmt, 0) == 0
        }
    }

    func all() -> [PersonRecord] {
        let people = fetchPeople()
        let aliasMap = fetchAliases()
        return people.map { p in
            var copy = p
            copy.aliases = aliasMap[p.id] ?? []
            return copy
        }
    }

    func contacts() -> [Contact] {
        all().map { $0.asContact() }
    }

    func upsert(contact: Contact) -> PersonRecord {
        let key = contact.name.lowercased()
        if let existing = all().first(where: { $0.name.lowercased() == key }) {
            var updated = existing
            updated.name = contact.name
            updated.company = contact.company
            updated.side = contact.side
            updated.title = contact.title
            updated.linkedin = contact.linkedin
            updated.aliases = contact.aliases
            updated.updatedAt = Date()
            save(updated)
            return updated
        }
        let now = Date()
        let record = PersonRecord(
            id: UUID().uuidString,
            name: contact.name,
            company: contact.company,
            side: contact.side,
            title: contact.title,
            linkedin: contact.linkedin,
            aliases: contact.aliases,
            createdAt: now,
            updatedAt: now
        )
        save(record)
        return record
    }

    func replaceAll(contacts: [Contact]) {
        db.withDB { sqlite in
            sqlite3_exec(sqlite, "DELETE FROM person_aliases;", nil, nil, nil)
            sqlite3_exec(sqlite, "DELETE FROM people;", nil, nil, nil)
        }
        for contact in contacts {
            _ = upsert(contact: contact)
        }
    }

    func delete(id: String) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, "DELETE FROM people WHERE id = ?;", -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    private func save(_ record: PersonRecord) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, """
                INSERT OR REPLACE INTO people(id, name, company, side, title, linkedin, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, record.id)
            KnowledgeSQL.bind(stmt, 2, record.name)
            KnowledgeSQL.bindOptional(stmt, 3, record.company)
            KnowledgeSQL.bind(stmt, 4, record.side.rawValue)
            KnowledgeSQL.bindOptional(stmt, 5, record.title)
            KnowledgeSQL.bindOptional(stmt, 6, record.linkedin)
            sqlite3_bind_double(stmt, 7, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 8, record.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        db.withDB { sqlite in
            var del: OpaquePointer?
            defer { sqlite3_finalize(del) }
            sqlite3_prepare_v2(sqlite, "DELETE FROM person_aliases WHERE person_id = ?;", -1, &del, nil)
            KnowledgeSQL.bind(del, 1, record.id)
            sqlite3_step(del)
        }
        for alias in record.aliases {
            db.withDB { sqlite in
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                sqlite3_prepare_v2(sqlite,
                    "INSERT OR IGNORE INTO person_aliases(person_id, alias) VALUES (?, ?);",
                    -1, &stmt, nil)
                KnowledgeSQL.bind(stmt, 1, record.id)
                KnowledgeSQL.bind(stmt, 2, alias)
                sqlite3_step(stmt)
            }
        }
    }

    private func fetchPeople() -> [PersonRecord] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT id, name, company, side, title, linkedin, created_at, updated_at
                FROM people ORDER BY name COLLATE NOCASE;
                """, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var rows: [PersonRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(PersonRecord(
                    id: KnowledgeSQL.text(stmt, 0),
                    name: KnowledgeSQL.text(stmt, 1),
                    company: KnowledgeSQL.optionalText(stmt, 2),
                    side: Side(rawValue: KnowledgeSQL.text(stmt, 3)) ?? .other,
                    title: KnowledgeSQL.optionalText(stmt, 4),
                    linkedin: KnowledgeSQL.optionalText(stmt, 5),
                    aliases: [],
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                ))
            }
            return rows
        }
    }

    private func fetchAliases() -> [String: [String]] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite,
                "SELECT person_id, alias FROM person_aliases ORDER BY alias;",
                -1, &stmt, nil) == SQLITE_OK else { return [:] }
            var map: [String: [String]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pid = KnowledgeSQL.text(stmt, 0)
                let alias = KnowledgeSQL.text(stmt, 1)
                map[pid, default: []].append(alias)
            }
            return map
        }
    }
}
