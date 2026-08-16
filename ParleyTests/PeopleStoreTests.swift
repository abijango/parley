import XCTest
@testable import Parley

final class PeopleStoreTests: XCTestCase {

    private func tempStore() -> (KnowledgeDatabase, PeopleStore) {
        let db = KnowledgeDatabase.openTemporary()
        return (db, PeopleStore(database: db))
    }

    func testAdrianStyleRoleHistoryRoundTrip() {
        let (db, store) = tempStore()
        var adrian = PersonRecord(
            id: UUID().uuidString,
            name: "Adrian Roberts",
            linkedin: nil,
            notes: "",
            aliases: [],
            createdAt: Date(),
            updatedAt: Date(),
            roles: [
                PersonRole(
                    id: UUID().uuidString, personId: "", company: "AWS", title: "Head of FSI SA",
                    team: nil, side: .customer, startedAt: Date(timeIntervalSince1970: 1_600_000_000),
                    endedAt: Date(), sortIndex: 0
                ),
                PersonRole(
                    id: UUID().uuidString, personId: "", company: "Databricks",
                    title: "Director of Regulated Industries",
                    team: nil, side: .customer, startedAt: Date(), endedAt: nil, sortIndex: 1
                ),
            ],
            origin: nil
        )
        store.save(adrian)

        let reloaded = PeopleStore(database: db).all()
        XCTAssertEqual(reloaded.count, 1)
        let record = reloaded[0]
        XCTAssertEqual(record.roles.count, 2)
        XCTAssertEqual(record.currentRole?.company, "Databricks")
        XCTAssertEqual(record.asContact().company, "Databricks")
        XCTAssertNotEqual(record.asContact().company, "AWS")
    }

    func testUpsertContactUpdatingTitlePreservesClosedRole() {
        let (_, store) = tempStore()
        var adrian = PersonRecord(
            id: UUID().uuidString,
            name: "Adrian Roberts",
            linkedin: nil,
            notes: "",
            aliases: [],
            createdAt: Date(),
            updatedAt: Date(),
            roles: [
                PersonRole(
                    id: UUID().uuidString, personId: "", company: "AWS", title: "Head of FSI SA",
                    team: nil, side: .customer, startedAt: nil, endedAt: Date(), sortIndex: 0
                ),
                PersonRole(
                    id: UUID().uuidString, personId: "", company: "Databricks",
                    title: "Director", team: nil, side: .customer,
                    startedAt: Date(), endedAt: nil, sortIndex: 1
                ),
            ],
            origin: nil
        )
        store.save(adrian)

        _ = store.upsert(contact: Contact(
            name: "Adrian Roberts", company: "Databricks", side: .customer,
            title: "Director of Regulated Industries, Databricks", linkedin: nil
        ))

        let record = store.all().first!
        XCTAssertEqual(record.roles.count, 2)
        XCTAssertEqual(record.roles.first { $0.company == "AWS" }?.title, "Head of FSI SA")
        XCTAssertEqual(record.currentRole?.title, "Director of Regulated Industries")
    }

    func testReplaceAllImportCreatesCurrentRoles() throws {
        let (_, store) = tempStore()
        let contacts = [
            Contact(name: "Alice", company: "Vanguard", side: .internalTeam,
                    title: "Engineer, Vanguard", linkedin: nil),
        ]
        store.replaceAll(contacts: contacts)
        let record = store.all().first!
        XCTAssertEqual(record.roles.count, 1)
        XCTAssertNil(record.roles[0].endedAt)
        XCTAssertEqual(record.asContact().company, "Vanguard")
    }

    func testMarkdownParseReplaceAllRoundTrip() throws {
        let (_, store) = tempStore()
        let markdown = """
        ## Vanguard
        - **Alice Smith** - Senior Engineer, Vanguard
        """
        let parsed = VaultDirectory.parseContacts(markdown)
        store.replaceAll(contacts: parsed)
        let exported = VaultDirectory.renderCanonical(store.contacts())
        let reparsed = VaultDirectory.parseContacts(exported)
        XCTAssertEqual(reparsed.count, 1)
        XCTAssertEqual(reparsed[0].name, "Alice Smith")
        XCTAssertEqual(reparsed[0].company, "Vanguard")
    }

    func testOriginRoundTrip() {
        let (_, store) = tempStore()
        var record = PersonRecord(
            id: UUID().uuidString,
            name: "Adrian Roberts",
            linkedin: nil,
            notes: "",
            aliases: [],
            createdAt: Date(),
            updatedAt: Date(),
            roles: [],
            origin: PersonOrigin(
                kind: .customer,
                date: Date(timeIntervalSince1970: 1_710_000_000),
                meetingId: nil,
                note: "introduced during the Vanguard FSI review"
            )
        )
        store.save(record)
        let loaded = store.all().first!
        XCTAssertEqual(loaded.origin?.kind, .customer)
        XCTAssertEqual(loaded.origin?.note, "introduced during the Vanguard FSI review")
    }

    func testPromptRendererScopesToAttendees() {
        let (_, store) = tempStore()
        _ = store.upsert(contact: Contact(
            name: "Adrian Roberts", company: "Databricks", side: .customer,
            title: "Director of Regulated Industries, Databricks", linkedin: nil
        ))
        var adrian = store.find(nameOrAlias: "Adrian Roberts")!
        adrian.roles.insert(
            PersonRole(
                id: UUID().uuidString, personId: adrian.id, company: "AWS", title: "Head of FSI SA",
                team: nil, side: .customer, startedAt: nil, endedAt: Date(), sortIndex: 0
            ),
            at: 0
        )
        adrian.origin = PersonOrigin(kind: .customer, date: Date(timeIntervalSince1970: 1_710_000_000),
                                     meetingId: nil, note: "introduced during the Vanguard FSI review")
        store.save(adrian)
        _ = store.upsert(contact: Contact(
            name: "Unrelated Person", company: "OtherCo", side: .other,
            title: "CEO, OtherCo", linkedin: nil
        ))

        let block = PeoplePromptRenderer.render(
            attendeeNames: ["Adrian Roberts", "Stranger"],
            records: store.all()
        )
        XCTAssertTrue(block.contains("Adrian Roberts"))
        XCTAssertTrue(block.contains("Databricks"))
        XCTAssertTrue(block.contains("AWS"))
        XCTAssertTrue(block.contains("Stranger"))
        XCTAssertFalse(block.contains("Unrelated Person"))
    }

    func testOpenRoleClosesExistingCurrent() {
        let (_, store) = tempStore()
        _ = store.upsert(contact: Contact(
            name: "Adrian Roberts", company: "AWS", side: .customer,
            title: "Head of FSI SA", linkedin: nil
        ))
        let id = store.find(nameOrAlias: "Adrian Roberts")!.id
        store.openRole(personId: id, company: "Databricks", title: "Director of Regulated Industries",
                       side: .customer)
        let record = store.find(id: id)!
        XCTAssertEqual(record.roles.filter { $0.endedAt == nil }.count, 1)
        XCTAssertEqual(record.currentRole?.company, "Databricks")
        XCTAssertEqual(record.roles.first { $0.company == "AWS" }?.endedAt != nil, true)
    }

    func testReplaceAllRecordsDoesNotDuplicate() {
        let (_, store) = tempStore()
        _ = store.upsert(contact: Contact(
            name: "Old Person", company: "Acme", side: .other, title: nil, linkedin: nil
        ))
        let adrian = PersonRecord(
            id: UUID().uuidString,
            name: "Adrian Roberts",
            linkedin: nil,
            notes: "",
            aliases: [],
            createdAt: Date(),
            updatedAt: Date(),
            roles: [
                PersonRole(
                    id: UUID().uuidString, personId: "", company: "Databricks",
                    title: "Director", team: nil, side: .customer,
                    startedAt: Date(), endedAt: nil, sortIndex: 0
                ),
            ],
            origin: nil
        )
        store.replaceAll(records: [adrian])
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.name, "Adrian Roberts")
    }

    func testPromptRendererEmptyAttendeesOmitsEveryone() {
        let (_, store) = tempStore()
        _ = store.upsert(contact: Contact(
            name: "Unrelated Person", company: "OtherCo", side: .other,
            title: "CEO", linkedin: nil
        ))
        let block = PeoplePromptRenderer.render(attendeeNames: [], records: store.all())
        XCTAssertEqual(block, "")
        XCTAssertFalse(block.contains("Unrelated Person"))
    }

    func testUpsertByAliasPreservesCanonicalName() {
        let (_, store) = tempStore()
        var record = PersonRecord(
            id: UUID().uuidString,
            name: "Adrian Roberts",
            linkedin: nil,
            notes: "",
            aliases: ["Adrian R"],
            createdAt: Date(),
            updatedAt: Date(),
            roles: [],
            origin: nil
        )
        store.save(record)
        var aliasContact = Contact(
            name: "Adrian R", company: "Databricks", side: .customer,
            title: "Director", linkedin: nil
        )
        aliasContact.aliases = ["Adrian R"]
        _ = store.upsert(contact: aliasContact)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.name, "Adrian Roberts")
    }

    func testUpsertOnEmptyDBCreatesCurrentRole() {
        let (_, store) = tempStore()
        _ = store.upsert(contact: Contact(
            name: "New Hire", company: "Acme", side: .internalTeam,
            title: "Engineer, Acme", linkedin: nil
        ))
        let record = store.all().first!
        XCTAssertEqual(record.roles.count, 1)
        XCTAssertNil(record.roles[0].endedAt)
        XCTAssertEqual(record.roles[0].company, "Acme")
    }

    func testPromptBuilderDoesNotDumpRolodexWhenAttendeesEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.md")
        try "hello".write(to: transcript, atomically: true, encoding: .utf8)
        let records = [
            PersonRecord(
                id: UUID().uuidString,
                name: "Unrelated Person",
                linkedin: nil,
                notes: "",
                aliases: [],
                createdAt: Date(),
                updatedAt: Date(),
                roles: [],
                origin: nil
            ),
        ]
        let built = SummaryPromptBuilder.build(
            template: "C:{{contacts}}",
            transcriptURL: transcript,
            attendees: "",
            destination: "",
            contactsURL: nil,
            peopleRecords: records)
        XCTAssertFalse(built.prompt.contains("Unrelated Person"))
        XCTAssertTrue(built.prompt.contains("no matching people for this meeting"))
    }
}
