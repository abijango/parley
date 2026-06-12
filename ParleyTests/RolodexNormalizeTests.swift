import XCTest
@testable import Parley

/// Tests for the tolerant reader (parseContacts extended), canonical renderer (renderCanonical),
/// normalize+dedupe logic, and the preview generator that produces Rolodex.normalized.md
/// from the real vault file.
///
/// The preview generator test (testGenerateRealFilePreview) reads from the real vault and
/// writes .normalized.md + .normalize-report.md. It skips gracefully when the vault is absent.
/// It NEVER modifies Rolodex.md.
final class RolodexNormalizeTests: XCTestCase {

    // MARK: - Tolerant reader: legacy format shapes

    /// Plain "- Name - Title" bullets (no bold or link markup) must be parsed.
    func testPlainBulletNoBoldOrLink() {
        let text = "SwissQuote\n- Jean-Philippe Costa - VP Engineering\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        let c = contacts[0]
        XCTAssertEqual(c.name, "Jean-Philippe Costa")
        XCTAssertEqual(c.title, "VP Engineering")
        XCTAssertNil(c.linkedin)
        XCTAssertEqual(c.company, "SwissQuote")
    }

    /// Plain bullet with no separator at all: "- Name" (no title).
    func testPlainBulletNoTitle() {
        let text = "Acme\n- Julien DESCHOMBECK\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].name, "Julien DESCHOMBECK")
        XCTAssertNil(contacts[0].title)
    }

    /// Colon-suffix header "Intellias Team:" must be recognized as heading, map to "Intellias",
    /// and its bullets parsed as internalTeam side.
    func testColonHeaderParsedAsHeading() {
        let text = "Intellias Team:\n- **Naufal Mir** - Director of AI, FSI\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].name, "Naufal Mir")
        XCTAssertEqual(contacts[0].company, "Intellias")
        XCTAssertEqual(contacts[0].side, .internalTeam)
    }

    /// Tab-indented bullets still belong to the most recent heading.
    func testTabIndentedBulletsBelongToHeading() {
        // Without a Customers umbrella, a bare heading defaults to internalTeam.
        let text = "IG Group\n\t- **Anna Krylova** - Head of Revenue Operations\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].name, "Anna Krylova")
        XCTAssertEqual(contacts[0].company, "IG Group")
        XCTAssertEqual(contacts[0].side, .internalTeam)
        // With a Customers umbrella, the bare heading inherits customerMode -> customer side.
        let text2 = "Customers:\nIG Group\n\t- **Anna Krylova** - Head of Revenue Operations\n"
        let contacts2 = VaultDirectory.parseContacts(text2)
        XCTAssertEqual(contacts2[0].side, .customer)
    }

    /// A link bullet with a stray char after the closing paren (like ")i") is handled gracefully.
    func testLinkBulletWithStrayTrailingChar() {
        let text = "AWS\n- [Addy Dubhash](https://www.linkedin.com/in/advaitdubhashi/)i - AWS\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].name, "Addy Dubhash")
        // The stray "i" is dropped; title should be "AWS"
        XCTAssertEqual(contacts[0].title, "AWS")
        XCTAssertNotNil(contacts[0].linkedin)
    }

    // MARK: - Side detection: internal / customer / other

    func testInternalSideForIntellias() {
        let text = "## Intellias\n- **Naufal Mir** - Director of AI\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts[0].side, .internalTeam)
        XCTAssertEqual(contacts[0].company, "Intellias")
    }

    func testCustomerSideUnderCustomersUmbrella() {
        let text = "## Customers\n\n### Vanguard\n- **Alice** - Lead\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].side, .customer)
        XCTAssertEqual(contacts[0].company, "Vanguard")
    }

    func testOtherSideMapsToNilCompany() {
        let text = "## Other\n- **Vena Dawood**\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts[0].side, .other)
        XCTAssertNil(contacts[0].company)
    }

    func testLegacyCustomersBareHeadings() {
        let text = """
        Customers:
        SwissQuote
        - Jean-Philippe Costa - VP
        IG Group
        - **Anna Krylova** - Head
        """
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].company, "SwissQuote")
        XCTAssertEqual(contacts[0].side, .customer)
        XCTAssertEqual(contacts[1].company, "IG Group")
        XCTAssertEqual(contacts[1].side, .customer)
    }

    func testIntelliasBareHeadingAfterCustomers() {
        // After Customers: block, an Intellias heading should reset to internal.
        let text = """
        Customers:
        SwissQuote
        - Jean-Philippe Costa - VP

        Intellias
        - **Naufal Mir** - Director
        """
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].side, .customer)
        XCTAssertEqual(contacts[1].company, "Intellias")
        XCTAssertEqual(contacts[1].side, .internalTeam)
    }

    // MARK: - Customers umbrella company list

    func testFileCustomersFromCanonical() {
        let text = """
        ## Customers

        ### Vanguard
        - **Alice** - Lead

        ### ProAg
        - **Bob** - CIO
        """
        let contacts = VaultDirectory.parseContacts(text)
        let customers = contacts.filter { $0.side == .customer }.compactMap { $0.company }
        let unique = Array(Set(customers)).sorted()
        XCTAssertEqual(unique, ["ProAg", "Vanguard"])
    }

    func testFileCustomersLegacyFormat() {
        // Legacy bare headings under Customers: produce customer companies.
        let text = "Customers:\nIG Group\n- **Anna** - Head\nMan Group\n- **Jon** - Lead\n"
        let contacts = VaultDirectory.parseContacts(text)
        let customers = contacts.filter { $0.side == .customer }.compactMap { $0.company }
        let unique = Array(Set(customers)).sorted()
        XCTAssertEqual(unique, ["IG Group", "Man Group"])
    }

    func testFileCustomersExcludesOtherAndInternal() {
        let text = """
        Intellias Team:
        - **Naufal** - Director

        Customers:
        Acme
        - **Alice** - CTO

        Other
        - **Bob**
        """
        let contacts = VaultDirectory.parseContacts(text)
        let customers = contacts.filter { $0.side == .customer }.compactMap { $0.company }
        XCTAssertTrue(customers.contains("Acme"))
        XCTAssertFalse(customers.contains("Intellias"))
        XCTAssertFalse(customers.contains("Other"))
    }

    // MARK: - Dedupe: richest wins

    func testDedupeExactSameNameMergesRichest() {
        // Two entries for "Alice Smith": one plain under Other, one with company + title.
        let text = """
        Intellias Team:
        - Alice Smith - Senior Engineer

        Other
        - **Alice Smith**
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        // Should have exactly one Alice Smith in output.
        let contacts = VaultDirectory.parseContacts(canonical)
        let alices = contacts.filter { $0.name == "Alice Smith" }
        XCTAssertEqual(alices.count, 1)
        // Must have kept the company+title (richer entry).
        XCTAssertEqual(alices[0].company, "Intellias")
        XCTAssertNotNil(alices[0].title)
        // Report must mention a merge.
        XCTAssertTrue(report.contains("Alice Smith"), "Report should mention the merged name")
    }

    func testDedupeLinkedinWinsOverBold() {
        let text = """
        Vanguard
        - **Bob Jones** - Director
        - [Bob Jones](https://linkedin.com/in/bobjones) - Director
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let bobs = contacts.filter { $0.name == "Bob Jones" }
        XCTAssertEqual(bobs.count, 1)
        XCTAssertNotNil(bobs[0].linkedin)
    }

    func testDedupeDistinctNamesNotMerged() {
        // Hyphen-extended surnames that are genuinely different people must NOT be merged.
        // (Uses a non-Christina pair so the explicit Christina directive does not interfere.)
        let text = """
        Intellias Team:
        - **Jordan Lee** - Partnership Director
        - **Jordan Lee-Martinez** - Director of Partner Sales
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let jordans = contacts.filter { $0.name.hasPrefix("Jordan Lee") }
        XCTAssertEqual(jordans.count, 2, "Distinct hyphen-extended names must not be merged")
    }

    /// The explicit Christina merge must collapse the two known entries into one authoritative
    /// contact with the correct canonical name, alias, title, and LinkedIn URL.
    func testChristinaMergeProducesCorrectEntry() {
        let text = """
        ## Intellias
        - Christina Wharf - Partnership Director
        - **Christina Wharf-Bulsara** - Director of Partner Sales
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let christinas = contacts.filter { $0.name.lowercased().hasPrefix("christina wharf") }
        XCTAssertEqual(christinas.count, 1,
                       "Explicit Christina merge must collapse two entries into one")
        let c = christinas[0]
        XCTAssertEqual(c.name, "Christina Wharf-Bulsara",
                       "Canonical name must be Christina Wharf-Bulsara")
        XCTAssertEqual(c.title, "Partnership Director",
                       "Title must be Partnership Director (from the Wharf entry)")
        XCTAssertEqual(c.linkedin, "https://www.linkedin.com/in/christina-wharf-bulsara-1860353b/",
                       "LinkedIn URL must match the authoritative entry")
        XCTAssertTrue(c.aliases.contains("Christina Wharf"),
                      "Christina Wharf must be registered as an alias")
        XCTAssertTrue(report.contains("Explicit person merges"),
                      "Report must include Explicit person merges section")
        XCTAssertTrue(report.contains("Christina Wharf-Bulsara"),
                      "Merged name must appear in report")
    }

    // MARK: - LinkedIn-merge (Rule 1)

    /// Two contacts with the SAME LinkedIn URL must be collapsed into one entry.
    /// The chosen name should be the one WITHOUT a trailing parenthetical.
    func testLinkedinMergeCollapsesSameURL() {
        // Real Tushara Fernando case: two entries, same LinkedIn, one has "(London)" suffix.
        let text = """
        Man Group
        - [Tushara Fernando (London)](https://linkedin.com/in/tusharafernando/) - Head of Data
        - [Tushara Fernando](https://linkedin.com/in/tusharafernando/) - Managing Director
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let tusharas = contacts.filter { $0.name.hasPrefix("Tushara Fernando") }
        XCTAssertEqual(tusharas.count, 1, "Same LinkedIn URL must collapse to one entry")
        XCTAssertEqual(tusharas[0].name, "Tushara Fernando",
                       "Name without parenthetical is preferred over 'Tushara Fernando (London)'")
        XCTAssertTrue(report.contains("linkedin-merge"), "Report must have linkedin-merge section")
        XCTAssertTrue(report.contains("Tushara Fernando"), "Merged name must appear in report")
    }

    /// LinkedIn URL normalization must be scheme- and slash-insensitive.
    /// Uses two contacts with DIFFERENT names so name-merge does not fire first —
    /// only linkedin-merge can collapse them.
    func testLinkedinMergeNormalizesURL() {
        // http vs https, with and without trailing slash, www vs no-www.
        // Names differ so name-merge is not triggered; only linkedin-merge fires.
        let text = """
        Acme
        - [Alice Norris (LinkedIn http)](http://www.linkedin.com/in/alicenorris/) - VP
        - [Alice Norris](https://linkedin.com/in/alicenorris) - VP Engineering
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let alices = contacts.filter { $0.name.hasPrefix("Alice Norris") }
        XCTAssertEqual(alices.count, 1, "http/https, www, and trailing-slash differences must be normalized to same key")
        // The name WITHOUT a parenthetical must be preferred.
        XCTAssertEqual(alices[0].name, "Alice Norris")
        XCTAssertTrue(report.contains("linkedin-merge"), "Report must contain linkedin-merge section")
    }

    /// Two contacts with DIFFERENT LinkedIn URLs and prefix+parenthetical names must NOT be
    /// merged by linkedin-merge; they should appear as a near-duplicate pair in the report.
    func testNearDuplicateFlaggedWhenDifferentLinkedin() {
        // Different LinkedIn URLs -> linkedin-merge does not fire; near-dup detector does.
        let text = """
        Acme
        - [Sarah Jones (NYC)](https://linkedin.com/in/sarahjonesnew/) - Director
        - [Sarah Jones](https://linkedin.com/in/sarahjones/) - VP
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let sarahs = contacts.filter { $0.name.hasPrefix("Sarah Jones") }
        XCTAssertEqual(sarahs.count, 2, "Different LinkedIn URLs must NOT collapse; keep both")
        XCTAssertTrue(report.contains("Near-duplicate"), "Near-dup section must appear in report")
        XCTAssertTrue(report.contains("Sarah Jones"), "Near-dup names must appear in report")
    }

    // MARK: - Orphan drop (Rule 2)

    /// The "Dubhashi" Other entry must be explicitly dropped.
    func testDubhashiOrphanDropped() {
        let text = """
        Other
        - **Dubhashi**
        - **Conan O'Brien**
        - **Ryan Gosling**
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        XCTAssertFalse(contacts.contains(where: { $0.name.caseInsensitiveCompare("Dubhashi") == .orderedSame }),
                       "Dubhashi orphan must be dropped")
        // Celebrities must be kept.
        XCTAssertTrue(contacts.contains(where: { $0.name == "Conan O'Brien" }), "Celebrities must not be dropped")
        XCTAssertTrue(contacts.contains(where: { $0.name == "Ryan Gosling" }), "Celebrities must not be dropped")
        XCTAssertTrue(report.contains("Dubhashi"), "Drop must be noted in report")
        XCTAssertTrue(report.contains("Explicit drops"), "Report must have Explicit drops section")
    }

    // MARK: - Title rewrites (Rules 3 + 4)

    /// Rule 3: strip redundant company suffix from title when it matches the section company.
    func testTitleCompanySuffixStrippedWhenMatches() {
        let text = """
        ## Customers

        ### IG Group
        - **Anna Krylova** - Head of Revenue Operations, IG Group
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let anna = contacts.first { $0.name == "Anna Krylova" }
        XCTAssertNotNil(anna)
        XCTAssertEqual(anna?.title, "Head of Revenue Operations",
                       "', IG Group' suffix must be stripped when it matches the section company")
    }

    /// Rule 3 must NOT strip a trailing company that differs from the section company.
    func testTitleCompanySuffixKeptWhenDifferent() {
        let text = """
        ## Intellias
        - **Tom Riley** - Account Manager, ProAg
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let tom = contacts.first { $0.name == "Tom Riley" }
        XCTAssertNotNil(tom)
        XCTAssertEqual(tom?.title, "Account Manager, ProAg",
                       "', ProAg' must NOT be stripped under Intellias because ProAg != Intellias")
    }

    /// Rule 3 must also fire on Intellias contacts whose title ends with ", Intellias".
    func testTitleCompanySuffixStrippedForIntelliasContacts() {
        let text = """
        ## Intellias
        - **Naufal Mir** - Director of AI, Intellias
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let naufal = contacts.first { $0.name == "Naufal Mir" }
        XCTAssertNotNil(naufal)
        XCTAssertEqual(naufal?.title, "Director of AI",
                       "', Intellias' suffix must be stripped for contacts in the Intellias section")
    }

    /// Rule 4: title that equals the section company must be blanked.
    func testTitleEqualsSectionCompanyBlanked() {
        // Addy Dubhash under AWS with title "AWS" -> title should become nil.
        let text = """
        ## Customers

        ### AWS
        - [Addy Dubhash](https://linkedin.com/in/addydubhash/) - AWS
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let addy = contacts.first { $0.name == "Addy Dubhash" }
        XCTAssertNotNil(addy)
        XCTAssertNil(addy?.title, "Title 'AWS' under AWS section must be blanked (rule 4)")
    }

    /// Rules 3 and 4 must not affect contacts in the Other section (company == nil).
    func testTitleRewritesSkipOtherSection() {
        let text = """
        ## Other
        - **Ryan Gosling** - Hollywood
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let ryan = contacts.first { $0.name == "Ryan Gosling" }
        XCTAssertNotNil(ryan)
        XCTAssertEqual(ryan?.title, "Hollywood",
                       "Title rewrites must not touch contacts in Other (company == nil)")
    }

    // MARK: - renderCanonical round-trip

    /// parse(render(contacts)) == contacts (for contacts already in canonical form).
    func testRenderCanonicalRoundTrip() {
        let contacts: [Contact] = [
            Contact(name: "Naufal Mir", company: "Intellias", side: .internalTeam,
                    title: "Director of AI, FSI", linkedin: nil),
            Contact(name: "Alice Smith", company: "Vanguard", side: .customer,
                    title: "Lead", linkedin: nil),
            Contact(name: "Vena Dawood", company: nil, side: .other,
                    title: nil, linkedin: nil),
        ]
        let rendered = VaultDirectory.renderCanonical(contacts)
        let reparsed = VaultDirectory.parseContacts(rendered)

        // Sort both by name for comparison (render sorts; original array may be in any order).
        let sortedOriginal = contacts.sorted { $0.name < $1.name }
        let sortedReparsed = reparsed.sorted { $0.name < $1.name }

        XCTAssertEqual(sortedReparsed.count, sortedOriginal.count)
        for (orig, reparsed) in zip(sortedOriginal, sortedReparsed) {
            XCTAssertEqual(reparsed.name, orig.name)
            XCTAssertEqual(reparsed.company, orig.company)
            XCTAssertEqual(reparsed.side, orig.side)
            XCTAssertEqual(reparsed.title, orig.title)
            XCTAssertEqual(reparsed.linkedin, orig.linkedin)
        }
    }

    func testRenderCanonicalStructure() {
        let contacts: [Contact] = [
            Contact(name: "Naufal Mir", company: "Intellias", side: .internalTeam,
                    title: "Director", linkedin: nil),
            Contact(name: "Alice Smith", company: "Vanguard", side: .customer,
                    title: "Lead", linkedin: nil),
            Contact(name: "Bob Jones", company: "Vanguard", side: .customer,
                    title: nil, linkedin: "https://linkedin.com/in/bobjones"),
            Contact(name: "Vena Dawood", company: nil, side: .other,
                    title: nil, linkedin: nil),
        ]
        let rendered = VaultDirectory.renderCanonical(contacts)

        // Internal comes before Customers.
        let intelliasRange  = rendered.range(of: "## Intellias")
        let customersRange  = rendered.range(of: "## Customers")
        let vanguardRange   = rendered.range(of: "### Vanguard")
        let otherRange      = rendered.range(of: "## Other")

        XCTAssertNotNil(intelliasRange)
        XCTAssertNotNil(customersRange)
        XCTAssertNotNil(vanguardRange)
        XCTAssertNotNil(otherRange)

        XCTAssertTrue(intelliasRange!.lowerBound < customersRange!.lowerBound,
                      "Internal sections come before Customers umbrella")
        XCTAssertTrue(customersRange!.lowerBound < vanguardRange!.lowerBound,
                      "## Customers comes before ### Vanguard")
        XCTAssertTrue(vanguardRange!.lowerBound < otherRange!.lowerBound,
                      "Customer sub-sections come before ## Other")

        // LinkedIn bullet emitted correctly.
        XCTAssertTrue(rendered.contains("[Bob Jones](https://linkedin.com/in/bobjones)"))
        // Bold bullet with title.
        XCTAssertTrue(rendered.contains("- **Naufal Mir** - Director"))
        // Bare bold bullet (no title).
        XCTAssertTrue(rendered.contains("- **Vena Dawood**"))
        XCTAssertFalse(rendered.contains("- **Vena Dawood** -"), "No trailing ' - ' when title absent")
    }

    func testRenderCanonicalSortedBullets() {
        let contacts: [Contact] = [
            Contact(name: "Zara Smith", company: "Acme", side: .customer, title: nil, linkedin: nil),
            Contact(name: "Alice Brown", company: "Acme", side: .customer, title: nil, linkedin: nil),
            Contact(name: "Mike Jones", company: "Acme", side: .customer, title: nil, linkedin: nil),
        ]
        let rendered = VaultDirectory.renderCanonical(contacts)
        let aliceRange = rendered.range(of: "Alice Brown")!
        let mikeRange  = rendered.range(of: "Mike Jones")!
        let zaraRange  = rendered.range(of: "Zara Smith")!
        XCTAssertTrue(aliceRange.lowerBound < mikeRange.lowerBound)
        XCTAssertTrue(mikeRange.lowerBound < zaraRange.lowerBound)
    }

    // MARK: - Specific real-file dedup expectations

    func testSevensIntelliasOtherDedup() {
        // People listed both in Intellias Team (plain) and Other (bold bare)
        // must collapse to their Intellias entries.
        let text = """
        Intellias Team:
        - Roman Hulianok - Senior Sales Representative
        - Mark Stelmachenko - Delivery Manager

        Other
        - **Roman Hulianok**
        - **Mark Stelmachenko**
        """
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)

        let roman = contacts.filter { $0.name == "Roman Hulianok" }
        XCTAssertEqual(roman.count, 1, "Roman Hulianok must not be duplicated")
        XCTAssertEqual(roman[0].side, .internalTeam, "Intellias entry wins over Other")
        XCTAssertNotNil(roman[0].title)

        let mark = contacts.filter { $0.name == "Mark Stelmachenko" }
        XCTAssertEqual(mark.count, 1, "Mark Stelmachenko must not be duplicated")
        XCTAssertEqual(mark[0].side, .internalTeam)
    }

    func testDanielStangu() {
        // Daniel Stangu appears twice in Intellias Team (same section, same name).
        let text = "Intellias Team:\n- **Daniel Stangu** - SVP, Delivery\n- **Daniel Stangu** - SVP Delivery\n"
        let (canonical, _) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let daniels = contacts.filter { $0.name == "Daniel Stangu" }
        XCTAssertEqual(daniels.count, 1, "Duplicate Daniel Stangu entries must be merged to one")
    }

    // MARK: - Rolodex.md specific oddity: empty title from "- Name - " pattern

    func testEmptyTitleTrailingSeparator() {
        let text = "SwissQuote\n- Jean-Philippe Costa - \n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        // The trailing " - " with nothing after it must not bleed into the name.
        XCTAssertEqual(contacts[0].name, "Jean-Philippe Costa",
                       "Trailing separator must not be baked into the name")
        // "- " with nothing after: title should be nil (empty string treated as nil)
        XCTAssertNil(contacts[0].title, "Empty trailing '- ' should produce nil title")
    }

    /// All-caps name with trailing bare "-" (no space after it) must also be clean.
    func testTrailingDashNoSpaceAfter() {
        // Real SwissQuote pattern: "- Antonio MORISCO - " (outer trim removes trailing space)
        // producing "- Antonio MORISCO -" where the separator ends without a trailing space.
        let text = "SwissQuote\n- Antonio MORISCO - \n- Lorenzo Rossi - \n- Celine Simon - \n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 3)
        for c in contacts {
            XCTAssertFalse(c.name.hasSuffix("-"), "Name '\(c.name)' must not end with '-'")
            XCTAssertFalse(c.name.hasSuffix(" -"), "Name '\(c.name)' must not end with ' -'")
            XCTAssertNil(c.title, "Title must be nil for empty-role bullets")
        }
        XCTAssertEqual(contacts[0].name, "Antonio MORISCO")
        XCTAssertEqual(contacts[1].name, "Lorenzo Rossi")
        XCTAssertEqual(contacts[2].name, "Celine Simon")
    }

    // MARK: - Aliases (slice 8a)

    /// Parse `(aka A, B)` after the name token (bold form).
    func testParseAkaBold() {
        let text = "## Intellias\n- **Christina Wharf-Bulsara** (aka Christina Wharf) - Partnership Director\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        let c = contacts[0]
        XCTAssertEqual(c.name, "Christina Wharf-Bulsara")
        XCTAssertEqual(c.title, "Partnership Director")
        XCTAssertEqual(c.aliases, ["Christina Wharf"], "aka alias must be parsed from bold bullet")
    }

    /// Parse `(aka A, B)` after the name token (link form).
    func testParseAkaLink() {
        let text = "## Intellias\n- [Christina Wharf-Bulsara](https://linkedin.com/in/cwb/) (aka Christina Wharf, CW-B) - Partnership Director\n"
        let contacts = VaultDirectory.parseContacts(text)
        XCTAssertEqual(contacts.count, 1)
        let c = contacts[0]
        XCTAssertEqual(c.name, "Christina Wharf-Bulsara")
        XCTAssertEqual(c.title, "Partnership Director")
        XCTAssertEqual(c.aliases.sorted(), ["CW-B", "Christina Wharf"].sorted(),
                       "Multiple aka aliases must all be parsed")
    }

    /// Non-aka parentheticals like `(London)` and `(AWS)` must NOT be treated as aliases.
    func testNonAkaParentheticalNotParsedAsAlias() {
        // These patterns appear in the real file.
        let boldLine = "- **Tushara Fernando (London)** - Managing Director"
        let (name, title, _, aliases) = VaultDirectory.extractBulletFields(boldLine)
        XCTAssertEqual(name, "Tushara Fernando (London)")
        XCTAssertEqual(title, "Managing Director")
        XCTAssertTrue(aliases.isEmpty, "(London) must not be parsed as aka alias")

        // Title parenthetical after " - " separator: not aka.
        let boldLine2 = "- **Addy Dubhash** - Senior DevOps Engineer (AWS)"
        let (_, title2, _, aliases2) = VaultDirectory.extractBulletFields(boldLine2)
        XCTAssertEqual(title2, "Senior DevOps Engineer (AWS)")
        XCTAssertTrue(aliases2.isEmpty, "Title parenthetical must not be parsed as aka alias")
    }

    /// Renderer must emit `(aka ...)` sorted when aliases are present.
    func testBulletLineRendersAka() {
        let rendered = VaultDirectory.renderCanonical([
            { var c = Contact(name: "Christina Wharf-Bulsara", company: "Intellias",
                              side: .internalTeam, title: "Partnership Director", linkedin: nil)
              c.aliases = ["Christina Wharf"]
              return c }()
        ])
        XCTAssertTrue(rendered.contains("(aka Christina Wharf)"),
                      "Renderer must emit (aka ...) segment")
        XCTAssertTrue(rendered.contains("- **Christina Wharf-Bulsara** (aka Christina Wharf) - Partnership Director"),
                      "Full bullet line must match expected format")
    }

    /// Renderer with multiple aliases must sort them.
    func testBulletLineRendersAkaSorted() {
        var c = Contact(name: "Test Person", company: "Acme", side: .customer, title: nil, linkedin: nil)
        c.aliases = ["Zara T", "Alice T"]
        let rendered = VaultDirectory.renderCanonical([c])
        XCTAssertTrue(rendered.contains("(aka Alice T, Zara T)"),
                      "Aliases must be sorted in rendered output")
    }

    /// After adding aliases to a contact, the index built from parseContacts must expose both
    /// canonical name and alias. Verified by building a manual companyIndex (mirrors what
    /// VaultDirectory.refresh() builds) and checking both keys resolve.
    func testCompanyIndexResolvesAlias() {
        let text = "## Intellias\n- **Christina Wharf-Bulsara** (aka Christina Wharf) - Partnership Director\n"
        let contacts = VaultDirectory.parseContacts(text)
        // Build a companyIndex the same way refresh() does (for testability without a live vault).
        var companyIndex: [String: Set<String>] = [:]
        for c in contacts {
            let keysToRegister: [String] = [c.name.lowercased()] + c.aliases.map { $0.lowercased() }
            for key in keysToRegister {
                if let company = c.company {
                    companyIndex[key, default: []].insert(company)
                } else {
                    if companyIndex[key] == nil { companyIndex[key] = [] }
                }
            }
        }
        XCTAssertEqual(companyIndex["christina wharf-bulsara"], Set(["Intellias"]),
                       "Canonical name must be in company index")
        XCTAssertEqual(companyIndex["christina wharf"], Set(["Intellias"]),
                       "Alias must also be in company index with same company")
    }

    /// company(for:) via a live VaultDirectory instance resolves both canonical and alias.
    @MainActor
    func testVaultCompanyForResolvesAlias() throws {
        let text = "## Intellias\n- **Christina Wharf-Bulsara** (aka Christina Wharf) - Partnership Director\n"
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliasTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let origVaultPath = AppSettings.shared.vaultPath
        let origContactsFileName = AppSettings.shared.contactsFileName
        AppSettings.shared.vaultPath = tmpDir.path
        AppSettings.shared.contactsFileName = "Rolodex.md"
        defer {
            AppSettings.shared.vaultPath = origVaultPath
            AppSettings.shared.contactsFileName = origContactsFileName
        }

        let rolodexURL = tmpDir.appendingPathComponent("Rolodex.md")
        try text.write(to: rolodexURL, atomically: true, encoding: .utf8)

        let vault = VaultDirectory()
        vault.refresh()

        XCTAssertEqual(vault.company(for: "Christina Wharf-Bulsara"), "Intellias",
                       "company(for:) must resolve canonical name")
        XCTAssertEqual(vault.company(for: "Christina Wharf"), "Intellias",
                       "company(for:) must resolve alias via the index")
        XCTAssertEqual(vault.side(for: "Christina Wharf"), .internalTeam,
                       "side(for:) must also resolve alias")
    }

    /// SummaryPromptBuilder.annotate must annotate attendees by alias.
    func testAnnotateResolvesAlias() {
        let contactsText = "## Intellias\n- **Christina Wharf-Bulsara** (aka Christina Wharf) - Partnership Director\n"
        // attendee is listed under her Teams display name (alias)
        let annotated = SummaryPromptBuilder.annotate(attendees: "Christina Wharf", contactsText: contactsText)
        XCTAssertEqual(annotated, "Christina Wharf (Intellias)",
                       "annotate must resolve alias to company")
    }

    /// Alias-merge in normalize: if A's name equals an alias of B, they should be merged.
    func testAliasMergeByAkaTag() {
        // The (aka ...) tag is present, so alias-merge in normalize should fire.
        let text = """
        ## Intellias
        - **Christina Wharf-Bulsara** (aka Christina Wharf) - Director
        - **Christina Wharf** - Partnership Director
        """
        let (canonical, report) = VaultDirectory.normalize(text)
        let contacts = VaultDirectory.parseContacts(canonical)
        let christinas = contacts.filter { $0.name.lowercased().hasPrefix("christina wharf") }
        XCTAssertEqual(christinas.count, 1, "Alias-merge must collapse the aka-tagged pair")
        XCTAssertTrue(report.contains("alias-merge"),
                      "Report must have alias-merge section")
    }

    /// Parse/render round-trip preserves aliases.
    func testAliasRoundTrip() {
        var c = Contact(name: "Christina Wharf-Bulsara", company: "Intellias",
                        side: .internalTeam, title: "Partnership Director", linkedin: nil)
        c.aliases = ["Christina Wharf"]
        let rendered = VaultDirectory.renderCanonical([c])
        let reparsed = VaultDirectory.parseContacts(rendered)
        XCTAssertEqual(reparsed.count, 1)
        XCTAssertEqual(reparsed[0].aliases, ["Christina Wharf"],
                       "Alias round-trips through render+parse")
    }

    // MARK: - Part 4: Generate preview from the real vault file

    /// This test reads the REAL Rolodex.md, normalizes it, and writes the preview files.
    /// It NEVER modifies the original Rolodex.md.
    ///
    /// Guard: skips gracefully when the vault file does not exist.
    func testGenerateRealFilePreview() throws {
        let vaultDir = URL(fileURLWithPath: "/Users/naufalmir/Vaults/ObsidianVault")
        let rolodexURL = vaultDir.appendingPathComponent("Rolodex.md")

        guard FileManager.default.fileExists(atPath: rolodexURL.path) else {
            print("RolodexNormalizeTests: skipping real-file preview -- Rolodex.md not found at \(rolodexURL.path)")
            return
        }

        // Capture original state before any writes.
        let originalText = try String(contentsOf: rolodexURL, encoding: .utf8)
        let originalAttribs = try FileManager.default.attributesOfItem(atPath: rolodexURL.path)
        let originalSize = originalAttribs[.size] as? Int ?? -1

        // Run the PURE normalize function (no instance methods, no disk writes to Rolodex.md).
        let (canonical, report) = VaultDirectory.normalize(originalText)

        // Write preview files.
        let previewURL = vaultDir.appendingPathComponent("Rolodex.normalized.md")
        let reportURL  = vaultDir.appendingPathComponent("Rolodex.normalize-report.md")
        try canonical.write(to: previewURL, atomically: true, encoding: .utf8)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        print("RolodexNormalizeTests: preview written to \(previewURL.path)")
        print("RolodexNormalizeTests: report written to \(reportURL.path)")

        // Parse the output to produce stats.
        let outContacts = VaultDirectory.parseContacts(canonical)
        let inContacts  = VaultDirectory.parseContacts(originalText)
        print("RolodexNormalizeTests: input=\(inContacts.count) output=\(outContacts.count) merges=\(inContacts.count - outContacts.count)")
        print("RolodexNormalizeTests: internal=\(outContacts.filter { $0.side == .internalTeam }.count) customer=\(outContacts.filter { $0.side == .customer }.count) other=\(outContacts.filter { $0.side == .other }.count)")

        // VERIFY: original Rolodex.md is byte-identical (not modified).
        let postText = try String(contentsOf: rolodexURL, encoding: .utf8)
        XCTAssertEqual(postText, originalText, "Rolodex.md must NOT be modified by the preview generator")

        let postAttribs = try FileManager.default.attributesOfItem(atPath: rolodexURL.path)
        let postSize = postAttribs[.size] as? Int ?? -2
        XCTAssertEqual(postSize, originalSize, "Rolodex.md file size must be identical after preview generation")

        // Sanity: canonical output is non-empty and has the expected structure.
        XCTAssertTrue(canonical.contains("## Intellias"), "Canonical output must have Intellias section")
        XCTAssertTrue(canonical.contains("## Customers"), "Canonical output must have Customers umbrella")
        XCTAssertTrue(canonical.contains("## Other"), "Canonical output must have Other section")
        XCTAssertFalse(outContacts.isEmpty, "At least one contact must be in the canonical output")

        // Sanity: report has the expected sections.
        XCTAssertTrue(report.contains("## Counts"), "Report must have Counts section")
        XCTAssertTrue(report.contains("Input contacts:"), "Report must have input count")
    }
}
