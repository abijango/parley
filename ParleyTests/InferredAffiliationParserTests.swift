import XCTest
@testable import Parley

/// Tests for InferredAffiliationParser.parseInferred and stripInferredTags.
final class InferredAffiliationParserTests: XCTestCase {

    // MARK: - parseInferred

    func testParseMixedTable() {
        let markdown = """
        # Meeting Note

        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice Smith | Engineer | Vanguard |
        | Dana Lee | Sales | Acme (inferred) |
        | Bob Jones | Director | |

        ## Executive Summary
        Some content.
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Dana Lee")
        XCTAssertEqual(result[0].company, "Acme")
    }

    func testParseMultipleInferred() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Vanguard (inferred) |
        | Bob | PM | GoldStar (inferred) |
        | Carol | Director | Acme |
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[0].company, "Vanguard")
        XCTAssertEqual(result[1].name, "Bob")
        XCTAssertEqual(result[1].company, "GoldStar")
    }

    func testParseNoneInferred() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Vanguard |
        | Bob | PM | Acme |
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertTrue(result.isEmpty)
    }

    func testParseNoAttendeesSection() {
        let markdown = """
        ## Executive Summary
        No attendees section here.
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertTrue(result.isEmpty)
    }

    func testParseCaseInsensitiveTag() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Vanguard (Inferred) |
        | Bob | PM | Acme (INFERRED) |
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].company, "Vanguard")
        XCTAssertEqual(result[1].company, "Acme")
    }

    func testParseWhitespaceVariants() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        |  Dana Lee  |  Sales  |  Acme (inferred)  |
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Dana Lee")
        XCTAssertEqual(result[0].company, "Acme")
    }

    func testParseBlankCompanyRowSkipped() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | (inferred) |
        """
        // Company is empty after stripping the tag -- row should be skipped.
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertTrue(result.isEmpty)
    }

    func testParseBoldNameStripped() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | **Dana Lee** | Sales | Acme (inferred) |
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Dana Lee")
    }

    func testParseLinkNameStripped() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | [Dana Lee](https://linkedin.com/in/danalee) | Sales | Acme (inferred) |
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Dana Lee")
    }

    func testParseOnlyInferredSection() {
        // Stops at the next ## heading.
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Dana | Sales | Acme (inferred) |

        ## Executive Summary

        | Name | Role | Company |
        |------|------|---------|
        | Ghost | Eng | Phantom (inferred) |
        """
        // Only Dana from the Attendees section; Ghost is in a different section.
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Dana")
    }

    // MARK: - stripInferredTags

    func testStripInferredTagsBasic() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Vanguard |
        | Dana | Sales | Acme (inferred) |

        ## Next Steps
        Some content.
        """
        let result = InferredAffiliationParser.stripInferredTags(markdown: markdown)
        XCTAssertFalse(result.contains("(inferred)"))
        XCTAssertTrue(result.contains("| Acme |"))
        XCTAssertTrue(result.contains("Some content."))
    }

    func testStripInferredTagsCaseInsensitive() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Vanguard (INFERRED) |
        | Dana | Sales | Acme (Inferred) |
        """
        let result = InferredAffiliationParser.stripInferredTags(markdown: markdown)
        XCTAssertFalse(result.lowercased().contains("(inferred)"))
        XCTAssertTrue(result.contains("| Vanguard |"))
        XCTAssertTrue(result.contains("| Acme |"))
    }

    func testStripInferredTagsOutsideSectionUntouched() {
        // The strip only operates on the Attendees table; text outside should be unchanged.
        let markdown = """
        ## Executive Summary
        Alice is from Acme (inferred) based on the call.

        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Dana | Sales | Acme (inferred) |
        """
        let result = InferredAffiliationParser.stripInferredTags(markdown: markdown)
        // Table cell should be stripped.
        XCTAssertTrue(result.contains("| Acme |"))
        // The non-table sentence in Executive Summary should still have the tag
        // (it's outside the Attendees section).
        XCTAssertTrue(result.contains("Acme (inferred) based on the call."))
    }

    func testStripInferredTagsNoSectionUnchanged() {
        let markdown = "No attendees section at all."
        let result = InferredAffiliationParser.stripInferredTags(markdown: markdown)
        XCTAssertEqual(result, markdown)
    }
}
