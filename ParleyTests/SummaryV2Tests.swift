import XCTest
@testable import Parley

final class SummaryV2Tests: XCTestCase {

    func testEditJSONParse_emptyEditsIsOK() {
        let result = SummaryEditJSONParser.parse(raw: #"{ "edits": [] }"#, runID: "run-1")
        XCTAssertTrue(result.parseOK)
        XCTAssertTrue(result.hunks.isEmpty)
    }

    func testHunkMerge_replaceOnlyFirstOccurrence() {
        let draft = "alpha beta alpha"
        var hunk = SummaryHunk.pending(runID: "r", sortIndex: 0, op: .replace,
                                       target: "alpha", text: "ALPHA", reason: "once")
        hunk.status = .accepted
        let merged = SummaryHunkEngine.mergedMarkdown(draft: draft, hunks: [hunk])
        XCTAssertEqual(merged, "ALPHA beta alpha")
    }

    func testEditJSONParse_withFences() {
        let raw = """
        ```json
        {
          "edits": [
            { "op": "replace", "target": "foo", "text": "bar", "reason": "typo" },
            { "op": "insert", "after_anchor": "## Summary", "text": "More", "reason": "missing" }
          ]
        }
        ```
        """
        let result = SummaryEditJSONParser.parse(raw: raw, runID: "run-1")
        XCTAssertTrue(result.parseOK)
        XCTAssertEqual(result.hunks.count, 2)
        XCTAssertEqual(result.hunks[0].op, .replace)
        XCTAssertEqual(result.hunks[0].target, "foo")
        XCTAssertEqual(result.hunks[1].op, .insert)
    }

    func testEditJSONParse_invalidReturnsEmpty() {
        let result = SummaryEditJSONParser.parse(raw: "not json", runID: "run-1")
        XCTAssertFalse(result.parseOK)
        XCTAssertTrue(result.hunks.isEmpty)
    }

    func testHunkMerge_applyAcceptedOnly() {
        let draft = "Hello world. Goodbye world."
        let hunks = [
            SummaryHunk.pending(runID: "r", sortIndex: 0, op: .replace,
                                target: "Goodbye", text: "Farewell", reason: "tone"),
            SummaryHunk.pending(runID: "r", sortIndex: 1, op: .replace,
                                target: "Hello", text: "Hi", reason: "skip")
        ]
        var accepted = hunks
        accepted[0].status = .accepted
        accepted[1].status = .rejected
        let merged = SummaryHunkEngine.mergedMarkdown(draft: draft, hunks: accepted)
        XCTAssertEqual(merged, "Hello world. Farewell world.")
    }

    func testTerminologyPromptInjection() {
        let db = KnowledgeDatabase.openTemporary()
        let store = TerminologyStore(database: db)
        _ = store.insert(from: "IG", to: "IG Group", source: "test")
        let block = SummaryPromptBuilder.terminologyBlock(from: store)
        XCTAssertTrue(block.contains("IG"))
        XCTAssertTrue(block.contains("IG Group"))
        let prompt = SummaryPromptBuilder.injectTerminology(block, into: "Preamble\n\nTRANSCRIPT:\nbody")
        XCTAssertTrue(prompt.contains("Terminology glossary"))
        XCTAssertTrue(prompt.contains("IG Group"))
        XCTAssertTrue(prompt.range(of: "Terminology", options: .backwards)!.lowerBound
            < prompt.range(of: "TRANSCRIPT:", options: .backwards)!.lowerBound)
    }

    func testTerminologyCustomerScope() {
        let db = KnowledgeDatabase.openTemporary()
        let store = TerminologyStore(database: db)
        _ = store.insert(from: "Maya", to: "Maia", notes: "platform", source: "test", scope: "MAN Group")
        _ = store.insert(from: "Acme", to: "ACME", source: "test", scope: "Other Co")
        let man = store.promptBlock(forScope: "MAN Group")
        XCTAssertTrue(man.contains("Maya"))
        XCTAssertTrue(man.contains("Maia"))
        XCTAssertFalse(man.contains("Acme"))
        let other = store.promptBlock(forScope: "Other Co")
        XCTAssertTrue(other.contains("Acme"))
        XCTAssertFalse(other.contains("Maya"))
    }

    func testWholeWordReplace() {
        let text = "Maya agents; Mayan history; talk to Maya."
        let (out, n) = SummaryMarkupReviewView.replacingWholeWords(in: text, from: "Maya", to: "Maia")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(out, "Maia agents; Mayan history; talk to Maia.")
    }

    func testCustomerScopeFromFiling() {
        XCTAssertEqual(
            TerminologyStore.customerScope(fromFiling: "Work/Customers/MAN Group/Agentic"),
            "MAN Group")
    }

    func testKnowledgeExportImportRoundtrip() throws {
        let db = KnowledgeDatabase.openTemporary()
        let terms = TerminologyStore(database: db)
        let people = PeopleStore(database: db)
        _ = terms.insert(from: "Acme", to: "Acme Corp", source: "test")
        people.upsert(contact: Contact(name: "Alice", company: "Vanguard", side: .internalTeam,
                                       title: "Engineer", linkedin: nil))
        let data = try KnowledgeExportImport.exportJSON(terminology: terms, people: people)
        let db2 = KnowledgeDatabase.openTemporary()
        let terms2 = TerminologyStore(database: db2)
        let people2 = PeopleStore(database: db2)
        try KnowledgeExportImport.importJSON(data, terminology: terms2, people: people2)
        XCTAssertEqual(terms2.all().count, 1)
        XCTAssertEqual(people2.all().count, 1)
        XCTAssertEqual(people2.all().first?.name, "Alice")
    }
}
