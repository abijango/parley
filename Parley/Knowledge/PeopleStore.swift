import Foundation
import SQLite3

struct PersonRole: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let personId: String
    var company: String?
    var title: String?
    var team: String?
    var side: Side
    var startedAt: Date?
    var endedAt: Date?
    var sortIndex: Int

    var isCurrent: Bool { endedAt == nil }
}

struct PersonOrigin: Equatable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case meeting, intro, conference, customer, other

        var label: String {
            switch self {
            case .meeting: return "meeting"
            case .intro: return "intro"
            case .conference: return "conference"
            case .customer: return "customer"
            case .other: return "other"
            }
        }
    }

    var kind: Kind
    var date: Date?
    var meetingId: String?
    var note: String
}

/// Person row in the knowledge DB — roles hold employment history; origin is optional provenance.
struct PersonRecord: Equatable, Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var linkedin: String?
    var notes: String
    var aliases: [String]
    let createdAt: Date
    var updatedAt: Date
    var roles: [PersonRole]
    var origin: PersonOrigin?

    var currentRole: PersonRole? {
        roles.first { $0.endedAt == nil }
    }

    func asContact() -> Contact {
        guard let role = currentRole else {
            return Contact(name: name, company: nil, side: .other, title: nil,
                           linkedin: linkedin, aliases: aliases)
        }
        let baked = PersonTitleFormatting.bakedTitle(title: role.title, company: role.company)
        return Contact(name: name, company: role.company, side: role.side,
                       title: baked, linkedin: linkedin, aliases: aliases)
    }
}

/// What a meeting tells us about who is relevant, for scoping `{{contacts}}`.
struct MeetingContactContext: Sendable {
    var attendees: [String] = []
    var invitees: [String] = []
    var transcript: String = ""
    var ownerName: String = ""
    var ownerCompany: String = ""
}

/// Meeting-scoped contacts block for summary prompts.
///
/// Sends people at the companies of the meeting's attendees and invitees, the owner's
/// company, and anyone whose full name or alias is spoken in the transcript — not
/// the whole DB. A bare first name ("Jason") is never enough on its own: it neither
/// confirms a contact nor pulls their company in, because a common first name
/// matches unrelated people (the Monument Hobbies "Jason" on an Intellias call).
enum PeoplePromptRenderer {
    static let header = "Full name | Title | Company | Aliases"

    static func render(records: [PersonRecord], context: MeetingContactContext) -> String {
        select(records: records, context: context).map(line(for:)).joined(separator: "\n")
    }

    static func select(records: [PersonRecord], context: MeetingContactContext) -> [PersonRecord] {
        let named = (context.attendees + context.invitees + [context.ownerName])
            .map(normalized).filter { !$0.isEmpty }

        var confirmed: [PersonRecord] = []
        var tentative: [PersonRecord] = []
        for name in named {
            for record in records {
                let viaAlias = record.aliases.contains { normalized($0) == name }
                guard normalized(record.name) == name || viaAlias else { continue }
                if isFullName(name) || viaAlias {
                    confirmed.append(record)
                } else {
                    tentative.append(record)
                }
            }
        }

        var companies = Set(confirmed.compactMap { companyKey($0) })
        let owner = normalized(context.ownerCompany)
        if !owner.isEmpty { companies.insert(owner) }

        let spoken = normalized(context.transcript)
        var picked: [PersonRecord] = []
        var seen = Set<String>()
        func take(_ record: PersonRecord) {
            if seen.insert(record.id).inserted { picked.append(record) }
        }
        confirmed.forEach(take)
        for record in tentative where companyKey(record).map(companies.contains) == true {
            take(record)
        }
        let rest = records
            .filter { !seen.contains($0.id) }
            .sorted {
                let a = ($0.currentRole?.company ?? "", $0.name), b = ($1.currentRole?.company ?? "", $1.name)
                return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedSame
                    ? a.1.localizedCaseInsensitiveCompare(b.1) == .orderedAscending
                    : a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
            }
        for record in rest {
            if companyKey(record).map(companies.contains) == true || isMentioned(record, in: spoken) {
                take(record)
            }
        }
        return picked
    }

    /// `Full name | Title | Company | Aliases`; blank fields stay as empty columns.
    static func line(for record: PersonRecord) -> String {
        let role = record.currentRole
        let title = role?.title?.trimmingCharacters(in: .whitespaces) ?? ""
        let company = role?.company?.trimmingCharacters(in: .whitespaces) ?? ""
        let aliases = record.aliases.joined(separator: ", ")
        return [record.name, title, company, aliases]
            .map { $0.isEmpty ? " " : " \($0) " }
            .joined(separator: "|")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isMentioned(_ record: PersonRecord, in spoken: String) -> Bool {
        guard !spoken.isEmpty else { return false }
        let full = normalized(record.name)
        if isFullName(full), containsWord(full, in: spoken) { return true }
        return record.aliases.contains { alias in
            let a = normalized(alias)
            return a.count >= 3 && containsWord(a, in: spoken)
        }
    }

    private static func containsWord(_ needle: String, in haystack: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    private static func companyKey(_ record: PersonRecord) -> String? {
        let key = normalized(record.currentRole?.company ?? "")
        return key.isEmpty ? nil : key
    }

    private static func isFullName(_ key: String) -> Bool { key.contains(" ") }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// CRUD for `people`, `person_roles`, `person_origins`, and `person_aliases`.
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
        let rolesMap = fetchRoles()
        let originsMap = fetchOrigins()
        let aliasMap = fetchAliases()
        return people.map { p in
            var copy = p
            copy.roles = rolesMap[p.id] ?? []
            copy.origin = originsMap[p.id]
            copy.aliases = aliasMap[p.id] ?? []
            return copy
        }
    }

    func contacts() -> [Contact] {
        all().map { $0.asContact() }
    }

    func find(nameOrAlias name: String) -> PersonRecord? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return all().first { record in
            record.name.lowercased() == key
                || record.aliases.contains { $0.lowercased() == key }
        }
    }

    func find(id: String) -> PersonRecord? {
        all().first { $0.id == id }
    }

    func upsert(contact: Contact) -> PersonRecord {
        let key = contact.name.lowercased()
        if let existing = all().first(where: { record in
            record.name.lowercased() == key
                || record.aliases.contains { $0.lowercased() == key }
        }) {
            var updated = existing
            let matchedByAlias = existing.name.lowercased() != key
            if !matchedByAlias {
                updated.name = contact.name
            }
            updated.linkedin = contact.linkedin
            updated.aliases = contact.aliases
            updated.updatedAt = Date()

            let stripped = PersonTitleFormatting.strippedTitle(contact.title, company: contact.company)
            let hasRoleData = contact.company != nil
                || (stripped.isEmpty == false)
                || contact.side != .other

            if let idx = updated.roles.firstIndex(where: { $0.endedAt == nil }) {
                if contact.company != nil { updated.roles[idx].company = contact.company }
                if !stripped.isEmpty || contact.title == nil {
                    updated.roles[idx].title = stripped.isEmpty ? nil : stripped
                }
                updated.roles[idx].side = contact.side
            } else if hasRoleData {
                updated.roles.append(makeRole(
                    personId: updated.id,
                    company: contact.company,
                    title: stripped.isEmpty ? nil : stripped,
                    side: contact.side,
                    sortIndex: updated.roles.count
                ))
            }

            save(updated)
            return updated
        }

        let now = Date()
        var roles: [PersonRole] = []
        let stripped = PersonTitleFormatting.strippedTitle(contact.title, company: contact.company)
        if contact.company != nil || !stripped.isEmpty || contact.side != .other {
            roles.append(makeRole(
                personId: "", // filled in save
                company: contact.company,
                title: stripped.isEmpty ? nil : stripped,
                side: contact.side,
                sortIndex: 0
            ))
        }

        let record = PersonRecord(
            id: UUID().uuidString,
            name: contact.name,
            linkedin: contact.linkedin,
            notes: "",
            aliases: contact.aliases,
            createdAt: now,
            updatedAt: now,
            roles: roles,
            origin: nil
        )
        save(record)
        return record
    }

    func replaceAll(contacts: [Contact]) {
        deleteAllPeople()
        for contact in contacts {
            insertFromContact(contact)
        }
    }

    func replaceAll(records: [PersonRecord]) {
        deleteAllPeople()
        for record in records {
            save(record)
        }
    }

    func save(_ record: PersonRecord) {
        let current = record.currentRole
        db.withDB { sqlite in
            sqlite3_exec(sqlite, "BEGIN IMMEDIATE;", nil, nil, nil)
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(sqlite, """
                INSERT OR REPLACE INTO people(
                    id, name, company, side, title, linkedin, notes, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, record.id)
            KnowledgeSQL.bind(stmt, 2, record.name)
            KnowledgeSQL.bindOptional(stmt, 3, current?.company)
            KnowledgeSQL.bind(stmt, 4, (current?.side ?? .other).rawValue)
            KnowledgeSQL.bindOptional(stmt, 5, current?.title)
            KnowledgeSQL.bindOptional(stmt, 6, record.linkedin)
            KnowledgeSQL.bind(stmt, 7, record.notes)
            sqlite3_bind_double(stmt, 8, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, record.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            var delRoles: OpaquePointer?
            sqlite3_prepare_v2(sqlite, "DELETE FROM person_roles WHERE person_id = ?;", -1, &delRoles, nil)
            KnowledgeSQL.bind(delRoles, 1, record.id)
            sqlite3_step(delRoles)
            sqlite3_finalize(delRoles)
            for role in record.roles {
                insertRole(sqlite, role, personId: record.id)
            }

            writeOrigin(sqlite, personId: record.id, origin: record.origin)

            var delAliases: OpaquePointer?
            sqlite3_prepare_v2(sqlite, "DELETE FROM person_aliases WHERE person_id = ?;", -1, &delAliases, nil)
            KnowledgeSQL.bind(delAliases, 1, record.id)
            sqlite3_step(delAliases)
            sqlite3_finalize(delAliases)
            for alias in record.aliases {
                var ins: OpaquePointer?
                sqlite3_prepare_v2(sqlite,
                    "INSERT OR IGNORE INTO person_aliases(person_id, alias) VALUES (?, ?);",
                    -1, &ins, nil)
                KnowledgeSQL.bind(ins, 1, record.id)
                KnowledgeSQL.bind(ins, 2, alias)
                sqlite3_step(ins)
                sqlite3_finalize(ins)
            }
            sqlite3_exec(sqlite, "COMMIT;", nil, nil, nil)
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

    func delete(name: String) {
        guard let record = find(nameOrAlias: name) else { return }
        delete(id: record.id)
    }

    func rename(from oldName: String, to newName: String) {
        guard var record = find(nameOrAlias: oldName) else { return }
        record.name = newName
        record.updatedAt = Date()
        let newLower = newName.lowercased()
        record.aliases = record.aliases.filter { $0.lowercased() != newLower }
        save(record)
    }

    func addAlias(_ alias: String, toCanonical canonicalName: String) {
        guard var record = find(nameOrAlias: canonicalName) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != record.name.lowercased() else { return }
        guard !record.aliases.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        record.aliases = (record.aliases + [trimmed]).sorted()
        record.updatedAt = Date()
        save(record)
    }

    func closeCurrentRole(personId: String, endedAt: Date = Date()) {
        guard var record = find(id: personId) else { return }
        guard let idx = record.roles.firstIndex(where: { $0.endedAt == nil }) else { return }
        record.roles[idx].endedAt = endedAt
        record.updatedAt = Date()
        save(record)
    }

    func openRole(personId: String, company: String?, title: String?, team: String? = nil,
                  side: Side, startedAt: Date = Date()) {
        guard var record = find(id: personId) else { return }
        if let idx = record.roles.firstIndex(where: { $0.endedAt == nil }) {
            record.roles[idx].endedAt = startedAt
        }
        let role = PersonRole(
            id: UUID().uuidString,
            personId: personId,
            company: company,
            title: title,
            team: team,
            side: side,
            startedAt: startedAt,
            endedAt: nil,
            sortIndex: record.roles.count
        )
        record.roles.append(role)
        record.updatedAt = Date()
        save(record)
    }

    func addPreviousRole(personId: String, company: String?, title: String?, side: Side,
                         startedAt: Date?, endedAt: Date) {
        guard var record = find(id: personId) else { return }
        let role = PersonRole(
            id: UUID().uuidString,
            personId: personId,
            company: company,
            title: title,
            team: nil,
            side: side,
            startedAt: startedAt,
            endedAt: endedAt,
            sortIndex: record.roles.count
        )
        record.roles.append(role)
        record.updatedAt = Date()
        save(record)
    }

    func setOrigin(personId: String, origin: PersonOrigin?) {
        db.withDB { sqlite in
            writeOrigin(sqlite, personId: personId, origin: origin)
        }
    }

    // MARK: - Private

    private func insertFromContact(_ contact: Contact) {
        let now = Date()
        let id = UUID().uuidString
        let stripped = PersonTitleFormatting.strippedTitle(contact.title, company: contact.company)
        var roles: [PersonRole] = []
        if contact.company != nil || !stripped.isEmpty || contact.side != .other {
            roles.append(makeRole(
                personId: id,
                company: contact.company,
                title: stripped.isEmpty ? nil : stripped,
                side: contact.side,
                sortIndex: 0
            ))
        }
        let record = PersonRecord(
            id: id,
            name: contact.name,
            linkedin: contact.linkedin,
            notes: "",
            aliases: contact.aliases,
            createdAt: now,
            updatedAt: now,
            roles: roles,
            origin: nil
        )
        save(record)
    }

    private func makeRole(personId: String, company: String?, title: String?,
                          side: Side, sortIndex: Int) -> PersonRole {
        PersonRole(
            id: UUID().uuidString,
            personId: personId,
            company: company,
            title: title,
            team: nil,
            side: side,
            startedAt: Date(),
            endedAt: nil,
            sortIndex: sortIndex
        )
    }

    private func deleteAllPeople() {
        db.withDB { sqlite in
            sqlite3_exec(sqlite, "DELETE FROM person_aliases;", nil, nil, nil)
            sqlite3_exec(sqlite, "DELETE FROM person_origins;", nil, nil, nil)
            sqlite3_exec(sqlite, "DELETE FROM person_roles;", nil, nil, nil)
            sqlite3_exec(sqlite, "DELETE FROM people;", nil, nil, nil)
        }
    }

    private func writeOrigin(_ sqlite: OpaquePointer, personId: String, origin: PersonOrigin?) {
        guard let origin else {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, "DELETE FROM person_origins WHERE person_id = ?;", -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, personId)
            sqlite3_step(stmt)
            return
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(sqlite, """
            INSERT OR REPLACE INTO person_origins(
                person_id, kind, occurred_at, meeting_id, note
            ) VALUES (?, ?, ?, ?, ?);
            """, -1, &stmt, nil)
        KnowledgeSQL.bind(stmt, 1, personId)
        KnowledgeSQL.bind(stmt, 2, origin.kind.rawValue)
        if let date = origin.date {
            sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        KnowledgeSQL.bindOptional(stmt, 4, origin.meetingId)
        KnowledgeSQL.bind(stmt, 5, origin.note)
        sqlite3_step(stmt)
    }

    private func insertRole(_ sqlite: OpaquePointer, _ role: PersonRole, personId: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(sqlite, """
            INSERT INTO person_roles(
                id, person_id, company, title, team, side, started_at, ended_at, sort_index
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, -1, &stmt, nil)
        KnowledgeSQL.bind(stmt, 1, role.id)
        KnowledgeSQL.bind(stmt, 2, personId)
        KnowledgeSQL.bindOptional(stmt, 3, role.company)
        KnowledgeSQL.bindOptional(stmt, 4, role.title)
        KnowledgeSQL.bindOptional(stmt, 5, role.team)
        KnowledgeSQL.bind(stmt, 6, role.side.rawValue)
        if let started = role.startedAt {
            sqlite3_bind_double(stmt, 7, started.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let ended = role.endedAt {
            sqlite3_bind_double(stmt, 8, ended.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int(stmt, 9, Int32(role.sortIndex))
        sqlite3_step(stmt)
    }

    private func fetchPeople() -> [PersonRecord] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT id, name, linkedin, notes, created_at, updated_at
                FROM people ORDER BY name COLLATE NOCASE;
                """, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var rows: [PersonRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(PersonRecord(
                    id: KnowledgeSQL.text(stmt, 0),
                    name: KnowledgeSQL.text(stmt, 1),
                    linkedin: KnowledgeSQL.optionalText(stmt, 2),
                    notes: KnowledgeSQL.text(stmt, 3),
                    aliases: [],
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    roles: [],
                    origin: nil
                ))
            }
            return rows
        }
    }

    private func fetchRoles() -> [String: [PersonRole]] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT id, person_id, company, title, team, side, started_at, ended_at, sort_index
                FROM person_roles ORDER BY person_id, sort_index, started_at;
                """, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            var map: [String: [PersonRole]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let personId = KnowledgeSQL.text(stmt, 1)
                let started: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let ended: Date? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                let role = PersonRole(
                    id: KnowledgeSQL.text(stmt, 0),
                    personId: personId,
                    company: KnowledgeSQL.optionalText(stmt, 2),
                    title: KnowledgeSQL.optionalText(stmt, 3),
                    team: KnowledgeSQL.optionalText(stmt, 4),
                    side: Side(rawValue: KnowledgeSQL.text(stmt, 5)) ?? .other,
                    startedAt: started,
                    endedAt: ended,
                    sortIndex: Int(sqlite3_column_int(stmt, 8))
                )
                map[personId, default: []].append(role)
            }
            return map
        }
    }

    private func fetchOrigins() -> [String: PersonOrigin] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT person_id, kind, occurred_at, meeting_id, note
                FROM person_origins;
                """, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            var map: [String: PersonOrigin] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let personId = KnowledgeSQL.text(stmt, 0)
                let kind = PersonOrigin.Kind(rawValue: KnowledgeSQL.text(stmt, 1)) ?? .other
                let date: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                map[personId] = PersonOrigin(
                    kind: kind,
                    date: date,
                    meetingId: KnowledgeSQL.optionalText(stmt, 3),
                    note: KnowledgeSQL.text(stmt, 4)
                )
            }
            return map
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
