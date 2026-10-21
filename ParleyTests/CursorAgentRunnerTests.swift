import XCTest
@testable import Parley

final class CursorAgentRunnerTests: XCTestCase {

    func testParseSuccessResult() {
        let json = """
        {"type":"result","subtype":"success","is_error":false,"result":"## Attendees\\n\\n| Name | Role | Company |","session_id":"x"}
        """
        switch CursorAgentRunner.parseJSONResult(stdout: json) {
        case .text(let note):
            XCTAssertTrue(note.hasPrefix("## Attendees"))
        default:
            XCTFail("expected .text")
        }
    }

    func testParseErrorFlag() {
        let json = #"{"type":"result","is_error":true,"result":"not logged in"}"#
        switch CursorAgentRunner.parseJSONResult(stdout: json) {
        case .error(let msg):
            XCTAssertTrue(msg.lowercased().contains("not logged in"))
        default:
            XCTFail("expected .error")
        }
    }

    func testSanitizeDropsPreamble() {
        let raw = "Thinking about the transcript…\n\n## Attendees\n\n| Name | Role | Company |"
        let cleaned = AgentCLI.sanitizeNoteText(raw)
        XCTAssertTrue(cleaned.hasPrefix("## Attendees"))
    }

    func testAuthPhrasesIncludeCursorExtras() {
        XCTAssertTrue(AgentCLI.looksLikeAuth("Error: Not logged in"))
        XCTAssertFalse(AgentCLI.looksLikeAuth("Missing API key"))
        XCTAssertTrue(AgentCLI.looksLikeAuth("Missing API key", extraPhrases: ["api key"]))
    }

    func testBackendCursorModelIDs() {
        XCTAssertEqual(SummaryBackend.composer25.cursorModelID, "composer-2.5")
        XCTAssertEqual(SummaryBackend.composer25Fast.cursorModelID, "composer-2.5-fast")
        XCTAssertEqual(SummaryBackend.cursorGrok46Fast.cursorModelID, "cursor-grok-4.6-high-fast")
        XCTAssertEqual(SummaryBackend.cursorGrok46Fast.displayName, "Cursor Grok 4.6 Fast")
        XCTAssertEqual(SummaryBackend.cursorGrok47Low.cursorModelID, "grok-4.7-low")
        XCTAssertEqual(SummaryBackend.cursorGrok47Medium.cursorModelID, "grok-4.7-medium")
        XCTAssertEqual(SummaryBackend.cursorGrok47Medium.statusName, "grok-4.7-medium")
        XCTAssertEqual(SummaryBackend.cursorGrok47MediumFast.cursorModelID, "grok-4.7-medium-fast")
        XCTAssertEqual(SummaryBackend.cursorGrok47MediumFast.displayName, "Cursor Grok 4.7 Medium Fast")
        XCTAssertEqual(SummaryBackend.cursorGrok47MediumFast.statusName, "grok-4.7-medium-fast")
        XCTAssertEqual(SummaryBackend.claude.statusName, "Claude")
        XCTAssertEqual(SummaryBackend.cursorGrok47Low.displayName, "Cursor Grok 4.7 Low")
        XCTAssertTrue(SummaryBackend.cursorGrok47Medium.isCursorAgent)
        XCTAssertTrue(SummaryBackend.cursorGrok47MediumFast.isCursorAgent)
        XCTAssertTrue(SummaryBackend.writerBackends.contains(.cursorGrok47Low))
        XCTAssertTrue(SummaryBackend.writerBackends.contains(.cursorGrok47MediumFast))
        XCTAssertTrue(SummaryBackend.checkerBackends.contains(.cursorGrok47Medium))
        XCTAssertTrue(SummaryBackend.checkerBackends.contains(.cursorGrok47MediumFast))
        XCTAssertEqual(SummaryBackend.resolved("cursor-grok-4.5-high"), .cursorGrok46Fast)
        XCTAssertEqual(SummaryBackend.resolved("cursor-grok-4.5-high-fast"), .cursorGrok46Fast)
        XCTAssertTrue(SummaryBackend.composer25.isCursorAgent)
        XCTAssertFalse(SummaryBackend.claude.isCursorAgent)
    }
}
