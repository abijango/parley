import XCTest
@testable import Parley

/// Tests for SummaryPromptBuilder.annotate(attendees:contactsText:).
///
/// annotate is a pure static helper with no @MainActor dependency, so these tests
/// run entirely on the test thread without any async/MainActor boilerplate.
final class SummaryPromptBuilderTests: XCTestCase {

    // MARK: - Sample Rolodex text

    /// Rolodex with:
    ///   Vanguard section: Alice Smith, Bob Jones
    ///   Acme section:     Carol White
    ///   Other section:    Dave Brown
    ///   Pre-section bare: EarlyBird (no company)
    ///   Collision:        Duplicated Name under both Vanguard and Acme
    private let sampleRolodex = """
    - **EarlyBird** - Contractor

    Vanguard

    - **Alice Smith** - Senior Engineer, Vanguard
    - [Bob Jones](https://linkedin.com/in/bobjones) - Director, Vanguard
    - **Duplicated Name** - Analyst

    Acme

    - **Carol White**
    - **Duplicated Name** - Manager

    Other

    - **Dave Brown** - Consultant
    """

    // MARK: - annotate tests

    /// A name under a named company section gets "(Company)" appended.
    func test_knownCompany_isAnnotated() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Alice Smith",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Alice Smith (Vanguard)")
    }

    /// A linkedin-style entry is also looked up correctly.
    func test_linkedinEntry_isAnnotated() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Bob Jones",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Bob Jones (Vanguard)")
    }

    /// A name under the "Other" section passes through bare (no annotation).
    func test_otherSection_isBare() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Dave Brown",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Dave Brown")
    }

    /// A name appearing before any section header (no company) passes through bare.
    func test_preSectionName_isBare() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "EarlyBird",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "EarlyBird")
    }

    /// A name absent from the rolodex entirely passes through bare.
    func test_unknownName_isBare() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Unknown Person",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Unknown Person")
    }

    /// Collision: same name under two different company sections -> bare (ambiguous).
    func test_collision_isBare() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Duplicated Name",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Duplicated Name",
                       "Ambiguous (two companies) -> leave bare, do not annotate")
    }

    /// Multiple attendees: known + unknown + Other in one comma-separated string.
    func test_multipleAttendees_mixedAnnotation() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Alice Smith, Dave Brown, Unknown Person",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Alice Smith (Vanguard), Dave Brown, Unknown Person")
    }

    /// Lookup is case-insensitive on the rolodex side; input casing is preserved.
    func test_caseInsensitiveLookup_preservesInputCasing() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "alice smith",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "alice smith (Vanguard)",
                       "Input casing preserved; company resolved case-insensitively")
    }

    /// Empty attendees string returns empty string (not "(none provided)").
    /// build() handles the empty guard; annotate itself just gets "" -> "".
    func test_emptyAttendees_returnsEmpty() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "")
    }

    /// Single name with extra whitespace is trimmed before lookup.
    func test_whitespaceTrimmingAroundName() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "  Carol White  ",
            contactsText: sampleRolodex
        )
        XCTAssertEqual(result, "Carol White (Acme)")
    }

    /// Empty contacts text means no rolodex -> all names pass through bare.
    func test_emptyContacts_allBare() {
        let result = SummaryPromptBuilder.annotate(
            attendees: "Alice Smith, Bob Jones",
            contactsText: ""
        )
        XCTAssertEqual(result, "Alice Smith, Bob Jones")
    }

    // MARK: - Side-aware annotation (customer vs internal)

    /// Customer-side contact gets ", customer" appended.
    func test_customerSide_appendsCustomerLabel() {
        let rolodex = """
        ## Customers

        ### IG Group

        - **Anna Krylova** - Head of Operations
        """
        let result = SummaryPromptBuilder.annotate(attendees: "Anna Krylova",
                                                   contactsText: rolodex)
        XCTAssertEqual(result, "Anna Krylova (IG Group, customer)")
    }

    /// Internal-side contact gets no ", customer" label.
    func test_internalSide_noCustomerLabel() {
        let rolodex = """
        ## Intellias

        - **Naufal Mir** - Director of AI, Intellias
        """
        let result = SummaryPromptBuilder.annotate(attendees: "Naufal Mir",
                                                   contactsText: rolodex)
        XCTAssertEqual(result, "Naufal Mir (Intellias)")
    }

    /// Mixed attendees: one internal, one customer, one unknown.
    func test_mixedSides_correctLabels() {
        let rolodex = """
        ## Intellias

        - **Alice** - Engineer

        ## Customers

        ### Vanguard

        - **Bob** - Analyst
        """
        let result = SummaryPromptBuilder.annotate(attendees: "Alice, Bob, Charlie",
                                                   contactsText: rolodex)
        XCTAssertEqual(result, "Alice (Intellias), Bob (Vanguard, customer), Charlie")
    }

    /// Alias resolves to customer-side contact with ", customer" label.
    func test_aliasOnCustomerSide_appendsCustomerLabel() {
        let rolodex = """
        ## Customers

        ### IG Group

        - **Anna Krylova-Smith** (aka Anna Krylova) - Head of Operations
        """
        let result = SummaryPromptBuilder.annotate(attendees: "Anna Krylova",
                                                   contactsText: rolodex)
        XCTAssertEqual(result, "Anna Krylova (IG Group, customer)")
    }

    /// Existing sampleRolodex uses bare section headers (parsed as internalTeam): no change to labels.
    func test_legacyBareHeaders_internalSideNoCustomerLabel() {
        // Alice is under "Vanguard" (bare heading -> internalTeam in the tolerant parser).
        let result = SummaryPromptBuilder.annotate(attendees: "Alice Smith",
                                                   contactsText: sampleRolodex)
        XCTAssertEqual(result, "Alice Smith (Vanguard)",
                       "Legacy bare-header company is internalTeam -> no customer label")
    }
}
