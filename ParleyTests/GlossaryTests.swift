import XCTest
@testable import Parley

final class GlossaryTests: XCTestCase {

    func testParseAndRenderEditorText() {
        let terms = GlossaryTerm.parse("""
        LSEG: Elseg, L Seg, LSEC
        # comment
        Intellias: Intellius

        Cursor
        """)
        XCTAssertEqual(terms.map(\.canonical), ["LSEG", "Intellias", "Cursor"])
        XCTAssertEqual(terms[0].aliases, ["Elseg", "L Seg", "LSEC"])
        XCTAssertEqual(terms[0].promptLine, "- LSEG (also heard as: Elseg, L Seg, LSEC)")
        XCTAssertEqual(terms[2].promptLine, "- Cursor")
    }

    func testReplaceGlobalGlossaryRoundTripsAndKeepsScopedCorrections() {
        let store = TerminologyStore(database: KnowledgeDatabase.openTemporary())
        _ = store.insert(from: "Maya", to: "Maia", notes: "platform", source: "review", scope: "MAN Group")
        _ = store.insert(from: "Elseg", to: "LSEG", notes: "London Stock Exchange Group", source: "review")

        store.replaceGlobalGlossary(with: "LSEG: Elseg, L Seg, LSEC\nIntellias: Intellius\nCursor")

        XCTAssertEqual(store.globalGlossaryText(), "Cursor\nIntellias: Intellius\nLSEG: Elseg, L Seg, LSEC")
        XCTAssertTrue(store.all().contains { $0.fromText == "Maya" && $0.scope == "MAN Group" })
        XCTAssertEqual(store.all().first { $0.fromText == "Elseg" }?.notes, "London Stock Exchange Group",
                       "a row that survives the edit keeps its notes")

        let block = store.promptBlock(forScope: nil)
        XCTAssertTrue(block.contains("- LSEG (also heard as: Elseg, L Seg, LSEC) — London Stock Exchange Group"))
        XCTAssertFalse(block.contains("Maia"), "customer-scoped corrections stay out of other meetings")
        XCTAssertTrue(store.promptBlock(forScope: "MAN Group").contains("Maia (also heard as: Maya)"))

        store.replaceGlobalGlossary(with: "LSEG: LSEC")
        XCTAssertEqual(store.globalGlossaryText(), "LSEG: LSEC")
    }

    func testCanonicalTermsForVocabulary() {
        let store = TerminologyStore(database: KnowledgeDatabase.openTemporary())
        store.replaceGlobalGlossary(with: "LSEG: Elseg\nLSEG: L Seg\nExperian")
        XCTAssertEqual(store.glossary().map(\.canonical), ["Experian", "LSEG"])
    }
}
