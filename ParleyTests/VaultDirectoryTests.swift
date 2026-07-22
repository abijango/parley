import XCTest
@testable import Parley

/// Tests for VaultDirectory's static parser, company lookup, and upsertPerson.
/// These tests exercise the nonisolated static APIs that Slice 2 (SummaryPromptBuilder)
/// depends on from a non-@MainActor context, plus the @MainActor instance methods
/// company(for:)/isCompanyKnown/upsertPerson via AppSettings redirection.
final class VaultDirectoryTests: XCTestCase {

    // MARK: - Sample Rolodex text (canonical format)

    /// A representative Rolodex.md with:
    /// - A bold-name bullet before any section header (no company)
    /// - A named company section ("Vanguard") with a bold-name bullet and a linkedin bullet
    /// - An "Other" section with a bare bold-name bullet
    /// - An "Acme" section with a bare bullet (no role)
    /// - A "Customers:" colon-header block (must produce no extra Contacts)
    private let sampleRolodex = """
    - **EarlyBird** - Contractor

    Vanguard

    - **Alice Smith** - Senior Engineer, Vanguard
    - [Bob Jones](https://linkedin.com/in/bobjones) - Director, Vanguard

    Acme

    - **Carol White**

    Other

    - **Dave Brown** - Consultant

    Customers:
    Vanguard
    Acme
    """

    // MARK: - Helpers

    /// Redirect AppSettings.shared to a temp directory with a given Rolodex text,
    /// call body(vault), then restore original settings.
    @MainActor
    private func withTempVault(rolodex text: String, body: @MainActor (VaultDirectory, URL) throws -> Void) throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VDTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Save originals and redirect
        let origVaultPath = AppSettings.shared.vaultPath
        let origContactsFileName = AppSettings.shared.contactsFileName
        AppSettings.shared.vaultPath = tmpDir.path
        AppSettings.shared.contactsFileName = "Rolodex.md"
        defer {
            AppSettings.shared.vaultPath = origVaultPath
            AppSettings.shared.contactsFileName = origContactsFileName
        }

        // Write the fixture
        let rolodexURL = tmpDir.appendingPathComponent("Rolodex.md")
        try text.write(to: rolodexURL, atomically: true, encoding: .utf8)

        let vault = VaultDirectory()
        vault.refresh(waitForCompletion: true)
        try body(vault, rolodexURL)
    }

    // MARK: - parseContacts (static, nonisolated)

    func testParseContactsExtractsAllBullets() {
        let contacts = VaultDirectory.parseContacts(sampleRolodex)
        let names = contacts.map { $0.name }
        XCTAssertTrue(names.contains("EarlyBird"), "Bullet before any section header should be parsed")
        XCTAssertTrue(names.contains("Alice Smith"))
        XCTAssertTrue(names.contains("Bob Jones"))
        XCTAssertTrue(names.contains("Carol White"))
        XCTAssertTrue(names.contains("Dave Brown"))
    }

    func testParseContactsCustomersBlockProducesNoContacts() {
        // "Vanguard" and "Acme" plain lines inside Customers block are not bullets
        // => no Contact emitted for them as names.
        // Total should be exactly 5 bullet contacts.
        let contacts = VaultDirectory.parseContacts(sampleRolodex)
        XCTAssertEqual(contacts.count, 5)
    }

    func testParseContactsCompanyAssignment() {
        let contacts = VaultDirectory.parseContacts(sampleRolodex)
        let byName = Dictionary(uniqueKeysWithValues: contacts.map { ($0.name, $0) })

        XCTAssertNil(byName["EarlyBird"]?.company, "Bullet before any section has nil company")
        XCTAssertEqual(byName["Alice Smith"]?.company, "Vanguard")
        XCTAssertEqual(byName["Bob Jones"]?.company, "Vanguard")
        XCTAssertEqual(byName["Carol White"]?.company, "Acme")
        XCTAssertNil(byName["Dave Brown"]?.company, "Contact under Other has nil company")
    }

    func testParseContactsDisplayRole() {
        let contacts = VaultDirectory.parseContacts(sampleRolodex)
        let byName = Dictionary(uniqueKeysWithValues: contacts.map { ($0.name, $0) })

        XCTAssertEqual(byName["Alice Smith"]?.displayRole, "Senior Engineer, Vanguard")
        // LinkedIn bullet: role after the closing paren
        XCTAssertEqual(byName["Bob Jones"]?.displayRole, "Director, Vanguard")
        // Bare bullet: empty displayRole (title is nil, displayRole returns "")
        XCTAssertEqual(byName["Carol White"]?.displayRole, "")
        XCTAssertEqual(byName["EarlyBird"]?.displayRole, "Contractor")
    }

    func testParseContactsOtherSectionCaseInsensitive() {
        // "other" in lowercase should still map company to nil, side to .other
        let text = "other\n- **Zara** - Freelancer\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertNil(contacts.first?.company)
        XCTAssertEqual(contacts.first?.side, .other)
    }

    func testParseContactsEmptyTextReturnsEmpty() {
        XCTAssertTrue(VaultDirectory.parseContacts("").isEmpty)
    }

    // MARK: - Verify nonisolated static is callable off @MainActor

    /// This test intentionally runs outside @MainActor to verify the contract
    /// that SummaryPromptBuilder (Slice 2) depends on: parseContacts must be
    /// callable from a background, non-@MainActor context without data races.
    func testParseContactsCalledOffMainActor() async {
        // Not marked @MainActor -- default XCTest context.
        let contacts = VaultDirectory.parseContacts("Vanguard\n- **Test Person**\n")
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts.first?.name, "Test Person")
        XCTAssertEqual(contacts.first?.company, "Vanguard")
    }

    // MARK: - company(for:) / isCompanyKnown(_:)

    @MainActor
    func testCompanyForKnownName() throws {
        try withTempVault(rolodex: sampleRolodex) { vault, _ in
            XCTAssertEqual(vault.company(for: "Alice Smith"), "Vanguard")
            XCTAssertEqual(vault.company(for: "alice smith"), "Vanguard",
                           "company(for:) must be case-insensitive")
            XCTAssertEqual(vault.company(for: "Bob Jones"), "Vanguard")
        }
    }

    @MainActor
    func testCompanyForOtherSectionReturnsNil() throws {
        try withTempVault(rolodex: sampleRolodex) { vault, _ in
            XCTAssertNil(vault.company(for: "Dave Brown"),
                         "Contact under Other section should return nil")
        }
    }

    @MainActor
    func testCompanyForUnknownNameReturnsNil() throws {
        try withTempVault(rolodex: sampleRolodex) { vault, _ in
            XCTAssertNil(vault.company(for: "Nobody Known"))
        }
    }

    @MainActor
    func testCompanyForCollisionReturnsNil() throws {
        // Same name under two different company sections -> ambiguous -> nil + logged
        let text = "Vanguard\n- **Jane Doe**\n\nAcme\n- **Jane Doe**\n"
        try withTempVault(rolodex: text) { vault, _ in
            XCTAssertNil(vault.company(for: "Jane Doe"),
                         "Name under two companies is ambiguous, must return nil")
        }
    }

    @MainActor
    func testCompanyForNameUnderCompanyAndOther() throws {
        // Name appears under a company section AND Other -> 1 distinct company -> not a collision
        let text = "Vanguard\n- **Sam Lee**\n\nOther\n- **Sam Lee**\n"
        try withTempVault(rolodex: text) { vault, _ in
            XCTAssertEqual(vault.company(for: "Sam Lee"), "Vanguard",
                           "Other entry does not create a collision; company section wins")
        }
    }

    @MainActor
    func testIsCompanyKnown() throws {
        try withTempVault(rolodex: sampleRolodex) { vault, _ in
            XCTAssertTrue(vault.isCompanyKnown("Alice Smith"))
            XCTAssertFalse(vault.isCompanyKnown("Dave Brown"), "Other-only contact not known")
            XCTAssertFalse(vault.isCompanyKnown("Nobody Known"))
        }
    }

    // MARK: - upsertPerson

    // MARK: - upsertPerson (canonical parse->mutate->render)

    @MainActor
    func testUpsertPersonPromotesFromOther() throws {
        // Start with a bare "Other" bullet for Alice. No existing Vanguard contacts, so
        // sideFor returns .customer -> entry goes under ## Customers / ### Vanguard.
        let initial = "## Other\n- **Alice Smith**\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.upsertPerson(name: "Alice Smith", title: "Senior Engineer", company: "Vanguard", linkedin: "")

            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let alice = contacts.first { $0.name == "Alice Smith" }
            XCTAssertNotNil(alice, "Alice must appear in output")
            XCTAssertEqual(alice?.company, "Vanguard", "Company must be Vanguard")
            XCTAssertEqual(alice?.side, .customer, "New company defaults to customer side")
            XCTAssertEqual(alice?.title, "Senior Engineer, Vanguard",
                           "Title field stores role+company string")
            // No bare Other bullet remains.
            let bareOther = contacts.filter { $0.name == "Alice Smith" && $0.side == .other }
            XCTAssertTrue(bareOther.isEmpty, "Bare Other entry must have been removed")
            // Index lookup must resolve.
            XCTAssertEqual(vault.company(for: "Alice Smith"), "Vanguard")
        }
    }

    @MainActor
    func testUpsertPersonIdempotency() throws {
        // Start with a canonical ## Vanguard section (internal side).
        // sideFor("Vanguard") finds the existing internal contact -> inherits .internalTeam.
        let initial = "## Vanguard\n- **Alice Smith** - Senior Engineer, Vanguard\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.upsertPerson(name: "Alice Smith", title: "Senior Engineer", company: "Vanguard", linkedin: "")
            vault.upsertPerson(name: "Alice Smith", title: "Senior Engineer", company: "Vanguard", linkedin: "")

            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let alices = contacts.filter { $0.name == "Alice Smith" }
            XCTAssertEqual(alices.count, 1, "Exactly one entry after two upserts (idempotent)")
            XCTAssertEqual(alices.first?.side, .internalTeam,
                           "Side inherited from existing Vanguard section (internal)")
        }
    }

    @MainActor
    func testUpsertPersonLinkedInBullet() throws {
        // Start with Other bare Bob Jones. Vanguard is new -> customer side.
        let initial = "## Other\n- **Bob Jones**\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.upsertPerson(name: "Bob Jones", title: "Director", company: "Vanguard",
                               linkedin: "https://linkedin.com/in/bobjones")

            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let bob = contacts.first { $0.name == "Bob Jones" }
            XCTAssertNotNil(bob, "Bob must appear in output")
            XCTAssertEqual(bob?.company, "Vanguard")
            XCTAssertEqual(bob?.linkedin, "https://linkedin.com/in/bobjones",
                           "LinkedIn URL must be preserved in bullet")
            // Bare Other entry must be gone.
            let bare = contacts.filter { $0.name == "Bob Jones" && $0.side == .other }
            XCTAssertTrue(bare.isEmpty, "Bare Other bullet must be removed")
        }
    }

    @MainActor
    func testUpsertPersonNoCompanyFilesUnderOther() throws {
        let initial = ""
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.upsertPerson(name: "New Person", title: "Freelancer", company: "", linkedin: "")

            let result = try String(contentsOf: rolodexURL, encoding: .utf8)
            let contacts = VaultDirectory.parseContacts(result)
            let person = contacts.first { $0.name == "New Person" }
            XCTAssertNotNil(person, "New Person must appear in output")
            XCTAssertEqual(person?.side, .other, "No-company entry must be filed under Other")
            XCTAssertNil(person?.company, "No-company entry has nil company")
            XCTAssertTrue(result.contains("## Other"), "Other section must use canonical ## heading")
        }
    }

    @MainActor
    func testAddPersonDelegatesToUpsert() throws {
        // addPerson should be dedup-safe via upsertPerson delegation.
        // Acme is new -> customer side.
        let initial = "## Other\n- **Carol White**\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.addPerson(name: "Carol White", title: "Engineer", company: "Acme", linkedin: "")

            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let carol = contacts.first { $0.name == "Carol White" }
            XCTAssertNotNil(carol, "Carol must appear in output")
            XCTAssertEqual(carol?.company, "Acme")
            // Bare Other entry must be gone (only one Carol entry total).
            XCTAssertEqual(contacts.filter { $0.name == "Carol White" }.count, 1,
                           "Exactly one entry after addPerson (dedup)")
        }
    }

    // MARK: - upsertPerson canonical write + round-trip

    /// Full round-trip: a fixture with all field combos survives parse->render->parse
    /// with every field intact. This guards the safety property of the canonical writer.
    func testCanonicalRoundTrip() {
        let fixture = """
        ## Intellias

        - **Naufal Mir** (aka NM) - Director of AI, Intellias

        ## Customers

        ### IG Group

        - [Anna Krylova](https://linkedin.com/in/annakrylova) - Head of Operations

        ### Vanguard

        - **Alice Smith** - Senior Engineer, Vanguard

        ## Other

        - **Dave Brown** - Consultant
        """
        let contacts = VaultDirectory.parseContacts(fixture)
        let rendered = VaultDirectory.renderCanonical(contacts)
        let recontacts = VaultDirectory.parseContacts(rendered)

        XCTAssertEqual(contacts.count, recontacts.count, "Round-trip must preserve contact count")

        // Check each contact by name.
        func byName(_ name: String, in arr: [Contact]) -> Contact? {
            arr.first { $0.name == name }
        }

        let naufal1 = byName("Naufal Mir", in: contacts)!
        let naufal2 = byName("Naufal Mir", in: recontacts)!
        XCTAssertEqual(naufal1.company, naufal2.company)
        XCTAssertEqual(naufal1.side, naufal2.side)
        XCTAssertEqual(naufal1.title, naufal2.title)
        XCTAssertEqual(naufal1.aliases, naufal2.aliases, "Aliases must survive round-trip")

        let anna1 = byName("Anna Krylova", in: contacts)!
        let anna2 = byName("Anna Krylova", in: recontacts)!
        XCTAssertEqual(anna1.side, .customer)
        XCTAssertEqual(anna1.side, anna2.side)
        XCTAssertEqual(anna1.linkedin, anna2.linkedin, "LinkedIn URL must survive round-trip")

        let dave1 = byName("Dave Brown", in: contacts)!
        let dave2 = byName("Dave Brown", in: recontacts)!
        XCTAssertEqual(dave1.side, .other)
        XCTAssertEqual(dave1.side, dave2.side)
    }

    /// Upserting via an alias must preserve the CANONICAL name + existing aliases + linkedin.
    @MainActor
    func testUpsertPersonByAliasPreservesCanonical() throws {
        // Fixture: Christina Wharf-Bulsara with alias "Christina Wharf" and a LinkedIn URL.
        let initial = """
        ## Intellias

        - [Christina Wharf-Bulsara](https://www.linkedin.com/in/cwb) (aka Christina Wharf) - Partnership Director
        """
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            // Upsert using the ALIAS name (not the canonical).
            vault.upsertPerson(name: "Christina Wharf", title: "Partnership Director",
                               company: "Intellias", linkedin: "")

            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            // Must be exactly one entry (no dup).
            XCTAssertEqual(contacts.count, 1, "Alias-matched upsert must not create a duplicate")
            let c = contacts[0]
            XCTAssertEqual(c.name, "Christina Wharf-Bulsara",
                           "Canonical name must be preserved when match is by alias")
            XCTAssertTrue(c.aliases.contains("Christina Wharf"),
                          "Original alias must be preserved")
            // Existing linkedin preserved (new upsert passes empty string).
            XCTAssertEqual(c.linkedin, "https://www.linkedin.com/in/cwb",
                           "Existing LinkedIn URL must be retained when upsert passes empty link")
        }
    }

    /// New company inherits side=.customer (external attendee default).
    @MainActor
    func testUpsertPersonNewCompanyDefaultsToCustomer() throws {
        let initial = ""
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.upsertPerson(name: "Keanu Rivers", title: "Account Manager",
                               company: "BrandNewCo", linkedin: "")
            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let keanu = contacts.first { $0.name == "Keanu Rivers" }
            XCTAssertEqual(keanu?.side, .customer,
                           "Upsert with a brand-new company name must default to customer side")
            let rendered = try String(contentsOf: rolodexURL, encoding: .utf8)
            XCTAssertTrue(rendered.contains("## Customers"), "Customer goes under ## Customers section")
            XCTAssertTrue(rendered.contains("### BrandNewCo"), "Customer company uses ### heading")
        }
    }

    /// Existing internal company side is inherited.
    @MainActor
    func testUpsertPersonExistingCompanyInheritesSide() throws {
        let initial = "## Intellias\n- **Alice** - Engineer\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.upsertPerson(name: "Bob", title: "Designer",
                               company: "Intellias", linkedin: "")
            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let bob = contacts.first { $0.name == "Bob" }
            XCTAssertEqual(bob?.side, .internalTeam,
                           "Upserting into an existing internal company must inherit internalTeam side")
        }
    }

    // MARK: - addPeople (canonical parse->mutate->render, alias-aware skip)

    @MainActor
    func testAddPeopleSkipsAlreadyKnownByAlias() throws {
        // Christina Wharf-Bulsara has alias "Christina Wharf".
        // addPeople with "Christina Wharf" should be a no-op (alias hit).
        let initial = """
        ## Intellias

        - [Christina Wharf-Bulsara](https://www.linkedin.com/in/cwb) (aka Christina Wharf) - Partnership Director
        """
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            let before = try String(contentsOf: rolodexURL, encoding: .utf8)
            vault.addPeople(["Christina Wharf"])
            let after = try String(contentsOf: rolodexURL, encoding: .utf8)
            XCTAssertEqual(before, after,
                           "addPeople must skip names already known as aliases (file must not change)")
        }
    }

    @MainActor
    func testAddPeopleAddsNewNamesUnderOther() throws {
        let initial = "## Intellias\n- **Alice** - Engineer\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            vault.addPeople(["Frank New", "Grace New"])
            let contacts = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8))
            let frank = contacts.first { $0.name == "Frank New" }
            let grace = contacts.first { $0.name == "Grace New" }
            XCTAssertNotNil(frank, "Frank New must be added")
            XCTAssertEqual(frank?.side, .other, "Fresh name goes under Other")
            XCTAssertNotNil(grace, "Grace New must be added")
        }
    }

    @MainActor
    func testAddPeopleSkipsAlreadyKnownCanonical() throws {
        let initial = "## Intellias\n- **Alice** - Engineer\n"
        try withTempVault(rolodex: initial) { vault, rolodexURL in
            let countBefore = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8)).count
            vault.addPeople(["Alice"])  // exact canonical name match
            let countAfter = VaultDirectory.parseContacts(try String(contentsOf: rolodexURL, encoding: .utf8)).count
            XCTAssertEqual(countBefore, countAfter,
                           "addPeople must not duplicate names already in the rolodex")
        }
    }

    // MARK: - suggestMatches (nonisolated static, pure)

    /// Build a minimal contact list used across suggestMatches tests.
    /// Deliberately excludes the (aka Christina Wharf) alias so that
    /// "Christina Wharf" is the *un-linked* state -- the exact scenario
    /// where a suggestion should be returned.
    private func suggestFixture() -> [Contact] {
        VaultDirectory.parseContacts("""
        Intellias

        - [Christina Wharf-Bulsara](https://www.linkedin.com/in/christina-wharf-bulsara-1860353b/) - Partnership Director
        - **Naufal Mir** - Director of AI, Intellias

        Castlelake

        - **Jordan Lee** - Analyst

        Other

        - **Completely Unrelated Person** - Freelancer
        """)
    }

    /// "Christina Wharf" is not yet an alias in the fixture; the helper must
    /// rank Christina Wharf-Bulsara as a match because token-subset holds:
    /// {christina, wharf} <= {christina, wharf, bulsara}.
    func testSuggestMatchesHyphenatedSurnameFamily() {
        let contacts = suggestFixture()
        let results = VaultDirectory.suggestMatches(for: "Christina Wharf", in: contacts)
        let names = results.map { $0.name }
        XCTAssertTrue(names.contains("Christina Wharf-Bulsara"),
                      "Token-subset match must surface hyphenated surname variant")
    }

    /// A truly random name that shares no tokens with anyone returns [].
    func testSuggestMatchesRandomNameReturnsEmpty() {
        let contacts = suggestFixture()
        let results = VaultDirectory.suggestMatches(for: "Zzyx Qwerty", in: contacts)
        XCTAssertTrue(results.isEmpty, "Unrelated name must return no suggestions")
    }

    /// An exact canonical-name hit must return [].
    func testSuggestMatchesExactHitReturnsEmpty() {
        let contacts = suggestFixture()
        let results = VaultDirectory.suggestMatches(for: "Christina Wharf-Bulsara", in: contacts)
        XCTAssertTrue(results.isEmpty, "Exact canonical name must return [] -- nothing to suggest")
    }

    /// An exact alias hit must also return [].
    func testSuggestMatchesAliasHitReturnsEmpty() {
        // Build a fixture that already has the alias registered.
        var contacts = suggestFixture()
        if let idx = contacts.firstIndex(where: { $0.name == "Christina Wharf-Bulsara" }) {
            contacts[idx].aliases = ["Christina Wharf"]
        }
        let results = VaultDirectory.suggestMatches(for: "Christina Wharf", in: contacts)
        XCTAssertTrue(results.isEmpty, "Exact alias hit must return [] -- person is already known")
    }

    /// Shared first token alone is a weaker signal but still surfaces a match.
    func testSuggestMatchesSharedFirstToken() {
        let contacts = suggestFixture()
        // "Jordan Martinez" shares "Jordan" with "Jordan Lee".
        let results = VaultDirectory.suggestMatches(for: "Jordan Martinez", in: contacts)
        let names = results.map { $0.name }
        XCTAssertTrue(names.contains("Jordan Lee"),
                      "Shared first token must surface a match")
    }

    /// Limit parameter is respected.
    func testSuggestMatchesLimitRespected() {
        // Build a fixture with many contacts all sharing "Smith".
        let text = """
        Acme

        - **John Smith** - Engineer
        - **Jane Smith** - Analyst
        - **James Smith** - Director
        - **Julia Smith** - Manager
        """
        let contacts = VaultDirectory.parseContacts(text)
        let results = VaultDirectory.suggestMatches(for: "Mark Smith", in: contacts, limit: 2)
        XCTAssertEqual(results.count, 2, "Limit parameter must cap returned results")
    }

    /// Empty query string returns [].
    func testSuggestMatchesEmptyNameReturnsEmpty() {
        let contacts = suggestFixture()
        let results = VaultDirectory.suggestMatches(for: "", in: contacts)
        XCTAssertTrue(results.isEmpty, "Empty name must return no suggestions")
    }

    /// Results are deterministic: same input always produces same order.
    func testSuggestMatchesDeterministicOrder() {
        let contacts = suggestFixture()
        let r1 = VaultDirectory.suggestMatches(for: "Christina Wharf", in: contacts)
        let r2 = VaultDirectory.suggestMatches(for: "Christina Wharf", in: contacts)
        XCTAssertEqual(r1.map { $0.name }, r2.map { $0.name },
                       "suggestMatches must be deterministic for identical input")
    }

    // MARK: - upsertPerson with explicit side parameter

    @MainActor
    func testUpsertPersonExplicitSideInternal() throws {
        let rolodex = ""
        try withTempVault(rolodex: rolodex) { vault, url in
            // A brand-new company would default to .customer, but we explicitly mark it Internal.
            vault.upsertPerson(name: "Jane Doe", title: "CEO", company: "NewCo",
                               linkedin: "", side: .internalTeam)
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            let jane = contacts.first { $0.name == "Jane Doe" }
            XCTAssertNotNil(jane)
            XCTAssertEqual(jane?.side, .internalTeam,
                           "Explicit side:.internalTeam must be honoured for a brand-new company")
            XCTAssertEqual(jane?.company, "NewCo")
        }
    }

    @MainActor
    func testUpsertPersonExplicitSideCustomer() throws {
        let rolodex = ""
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.upsertPerson(name: "Bob Smith", title: "VP", company: "ExternalCo",
                               linkedin: "", side: .customer)
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            let bob = contacts.first { $0.name == "Bob Smith" }
            XCTAssertEqual(bob?.side, .customer)
        }
    }

    @MainActor
    func testUpsertPersonEmptyCompanyForcesOtherRegardlessOfExplicitSide() throws {
        // Empty company must always resolve to .other, even if caller passes side:.internalTeam.
        let rolodex = ""
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.upsertPerson(name: "Anon Person", title: "", company: "",
                               linkedin: "", side: .internalTeam)
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            let person = contacts.first { $0.name == "Anon Person" }
            XCTAssertEqual(person?.side, .other,
                           "Empty company must always yield .other regardless of explicitSide")
            XCTAssertNil(person?.company)
        }
    }

    @MainActor
    func testUpsertPersonRoundTripTitleDoesNotDouble() throws {
        // Calling upsertPerson twice with the same title + company must not double the company suffix.
        let rolodex = ""
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.upsertPerson(name: "Alice Repeat", title: "Engineer", company: "Acme",
                               linkedin: "", side: .customer)
            // Re-upsert: the stored title is "Engineer, Acme"; we call with "Engineer" again.
            // The editor strips the suffix before passing back, simulating the round-trip.
            vault.upsertPerson(name: "Alice Repeat", title: "Engineer", company: "Acme",
                               linkedin: "", side: .customer)
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            let alice = contacts.first { $0.name == "Alice Repeat" }
            // Title as stored must NOT be "Engineer, Acme, Acme".
            XCTAssertFalse(alice?.title?.contains("Acme, Acme") ?? false,
                           "Re-upserting same title+company must not double the company suffix")
        }
    }

    // MARK: - renameContact

    @MainActor
    func testRenameContactPreservesAllFields() throws {
        let rolodex = "## Customers\n\n### Vanguard\n- [Alice Smith](https://linkedin.com/in/alice) (aka Ali) - Senior Engineer\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.renameContact(from: "Alice Smith", to: "Alice Jones")
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            // Old name must be gone.
            XCTAssertNil(contacts.first { $0.name == "Alice Smith" },
                         "Old name should not appear after rename")
            // New name should be present with all preserved fields.
            let renamed = contacts.first { $0.name == "Alice Jones" }
            XCTAssertNotNil(renamed, "Renamed contact must appear under new name")
            XCTAssertEqual(renamed?.company, "Vanguard")
            XCTAssertEqual(renamed?.side, .customer)
            XCTAssertEqual(renamed?.linkedin, "https://linkedin.com/in/alice")
            // Alias preserved.
            XCTAssertTrue(renamed?.aliases.contains("Ali") ?? false,
                          "Alias should be preserved across rename")
        }
    }

    @MainActor
    func testRenameContactByAlias() throws {
        // Rename when oldName matches an alias, not the canonical name.
        let rolodex = "## Intellias\n- **Christina Wharf-Bulsara** (aka Christina Wharf) - Director\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            // Rename using the alias "Christina Wharf" -> "Christina Jones"
            vault.renameContact(from: "Christina Wharf", to: "Christina Jones")
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            // The canonical "Christina Wharf-Bulsara" entry should now be "Christina Jones"
            let renamed = contacts.first { $0.name == "Christina Jones" }
            XCTAssertNotNil(renamed, "Renaming by alias should rename the canonical entry")
            XCTAssertEqual(renamed?.side, .internalTeam)
            XCTAssertEqual(renamed?.title?.contains("Director") ?? false, true)
        }
    }

    @MainActor
    func testRenameContactDropsAliasWhenNewNameMatchesAlias() throws {
        // If we rename to a name that is already listed as an alias, the alias should be dropped.
        let rolodex = "## Other\n- **Bob Extended** (aka Bob) - Consultant\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.renameContact(from: "Bob Extended", to: "Bob")
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            let renamed = contacts.first { $0.name == "Bob" }
            XCTAssertNotNil(renamed)
            // "Bob" alias should be removed since it's now the canonical name.
            XCTAssertFalse(renamed?.aliases.contains("Bob") ?? false,
                           "Alias matching new canonical name should be dropped")
        }
    }

    @MainActor
    func testRenameContactNoOpWhenNotFound() throws {
        // No crash, no change when old name not found.
        let rolodex = "## Other\n- **Real Person** - Consultant\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.renameContact(from: "Ghost Person", to: "New Name")
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            XCTAssertEqual(contacts.count, 1)
            XCTAssertEqual(contacts.first?.name, "Real Person",
                           "File should be unchanged when oldName not found")
        }
    }

    @MainActor
    func testRenameContactMergesOnCollision() throws {
        // When the newName already exists, the two contacts should be merged.
        let rolodex = "## Other\n- **Alice Old** - Engineer\n- **Alice New** - Senior Engineer\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.renameContact(from: "Alice Old", to: "Alice New")
            let updated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let contacts = VaultDirectory.parseContacts(updated)
            // Should have exactly 1 contact after merge.
            XCTAssertEqual(contacts.count, 1, "Collision rename should merge into one entry")
            XCTAssertEqual(contacts.first?.name, "Alice New")
        }
    }

    // MARK: - strippedTitle: bare-company round-trip (title == company stored by upsertPerson)

    func testStrippedTitleHandlesBareCompanyCase() {
        // upsertPerson stores just the company name in title when no title was provided.
        // e.g. upsertPerson(title:"", company:"Acme") -> stored title = "Acme".
        // strippedTitle must return "" so the editor shows an empty title field,
        // preventing a re-save from producing "Acme, Acme".
        XCTAssertEqual(
            PersonEditorView.strippedTitle("Acme", company: "Acme"),
            "",
            "Bare-company title should strip to empty string"
        )
        // Case-insensitive: stored value may differ in case from company field.
        XCTAssertEqual(
            PersonEditorView.strippedTitle("acme", company: "Acme"),
            "",
            "Case-insensitive bare-company match should strip to empty string"
        )
    }

    func testStrippedTitleHandlesTitlePlusCompany() {
        // Normal case: "Engineer, Acme" -> "Engineer".
        XCTAssertEqual(
            PersonEditorView.strippedTitle("Engineer, Acme", company: "Acme"),
            "Engineer"
        )
        // Nil company: title is returned as-is.
        XCTAssertEqual(
            PersonEditorView.strippedTitle("Engineer", company: nil),
            "Engineer"
        )
        // Nil title: returns empty string.
        XCTAssertEqual(
            PersonEditorView.strippedTitle(nil, company: "Acme"),
            ""
        )
    }

    // MARK: - upsertPerson clearLinkedinIfEmpty

    /// clearLinkedinIfEmpty:true + empty link removes an existing LinkedIn URL.
    @MainActor
    func testUpsertPersonClearLinkedinRemovesExistingURL() throws {
        let rolodex = "## Customers\n\n### Vanguard\n- [Alice Smith](https://linkedin.com/in/alice) - Engineer\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            // Confirm initial state: linkedin is set.
            let initial = vault.contacts.first { $0.name == "Alice Smith" }
            XCTAssertEqual(initial?.linkedin, "https://linkedin.com/in/alice")

            // Editor saves with empty linkedin and clearLinkedinIfEmpty:true -> should clear.
            vault.upsertPerson(name: "Alice Smith", title: "Engineer", company: "Vanguard",
                               linkedin: "", side: .customer, clearLinkedinIfEmpty: true)

            let updated = vault.contacts.first { $0.name == "Alice Smith" }
            XCTAssertNil(updated?.linkedin,
                         "clearLinkedinIfEmpty:true with empty link must remove existing URL")
        }
    }

    /// clearLinkedinIfEmpty:false (default) + empty link preserves existing LinkedIn URL.
    @MainActor
    func testUpsertPersonDefaultPreservesLinkedinWhenEmpty() throws {
        let rolodex = "## Customers\n\n### Vanguard\n- [Alice Smith](https://linkedin.com/in/alice) - Engineer\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            // Default (clearLinkedinIfEmpty:false) + empty link preserves existing URL.
            vault.upsertPerson(name: "Alice Smith", title: "Engineer", company: "Vanguard",
                               linkedin: "")

            let updated = vault.contacts.first { $0.name == "Alice Smith" }
            XCTAssertEqual(updated?.linkedin, "https://linkedin.com/in/alice",
                           "Default (clearLinkedinIfEmpty:false) with empty link must preserve existing URL")
        }
    }

    /// clearLinkedinIfEmpty:true with a non-empty link writes the new URL (not cleared).
    @MainActor
    func testUpsertPersonClearLinkedinFlagDoesNotClearNonEmptyLink() throws {
        let rolodex = "## Customers\n\n### Vanguard\n- [Alice Smith](https://linkedin.com/in/alice) - Engineer\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            vault.upsertPerson(name: "Alice Smith", title: "Engineer", company: "Vanguard",
                               linkedin: "https://linkedin.com/in/alice-new",
                               side: .customer, clearLinkedinIfEmpty: true)

            let updated = vault.contacts.first { $0.name == "Alice Smith" }
            XCTAssertEqual(updated?.linkedin, "https://linkedin.com/in/alice-new",
                           "Non-empty link must always be written regardless of clearLinkedinIfEmpty")
        }
    }

    /// clearLinkedinIfEmpty:true clears via the alias-match branch as well.
    @MainActor
    func testUpsertPersonClearLinkedinWorksForAliasMatch() throws {
        let rolodex = "## Customers\n\n### Vanguard\n- [Alice Smith](https://linkedin.com/in/alice) (aka Ali) - Engineer\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            // Upserting by alias "Ali" with clear flag should remove the URL.
            vault.upsertPerson(name: "Ali", title: "Engineer", company: "Vanguard",
                               linkedin: "", side: .customer, clearLinkedinIfEmpty: true)

            let updated = vault.contacts.first { $0.name == "Alice Smith" }
            XCTAssertNil(updated?.linkedin,
                         "clearLinkedinIfEmpty:true via alias match must also clear the URL")
        }
    }

    @MainActor
    func testUpsertPersonNoTitleRoundTripDoesNotDoubleCompany() throws {
        // Regression test for the bare-company doubling bug:
        // When a contact has no real title, upsertPerson stores just the company name
        // in the title field (the "else if let co" branch). If the editor reloads without
        // stripping this, the next save produces "Acme, Acme".
        //
        // The contact must be in a named company section (not ## Other) so that
        // parsing produces a non-nil company and the bare-company case is triggered.
        let rolodex = "## Customers\n### Acme\n- **No Title Person**\n"
        try withTempVault(rolodex: rolodex) { vault, url in
            // upsertPerson with no title creates a stored title equal to just the company name.
            vault.upsertPerson(name: "No Title Person", title: "", company: "Acme",
                               linkedin: "", side: .customer)

            // Verify that the stored title == company (this is the bare-company case).
            let initial = vault.contacts.first { $0.name == "No Title Person" }
            XCTAssertNotNil(initial)
            XCTAssertEqual(initial?.company, "Acme")
            XCTAssertEqual(initial?.title, "Acme",
                           "Sanity: upsert stores company as title when no title given")

            // Simulate editor load: strippedTitle must return "" for the bare-company case.
            let editorTitle = PersonEditorView.strippedTitle(initial?.title, company: initial?.company)
            XCTAssertEqual(editorTitle, "", "Editor must see empty title, not 'Acme'")

            // Simulate save with empty title (what the editor would pass).
            vault.upsertPerson(name: "No Title Person", title: editorTitle,
                               company: "Acme", linkedin: "", side: .customer)

            let afterSave = vault.contacts.first { $0.name == "No Title Person" }
            XCTAssertNotNil(afterSave)
            // Title should remain "Acme" (company fallback), NOT "Acme, Acme".
            XCTAssertEqual(afterSave?.title, "Acme",
                           "Title should not double to 'Acme, Acme' after round-trip save")
            XCTAssertEqual(afterSave?.company, "Acme")
        }
    }
}
