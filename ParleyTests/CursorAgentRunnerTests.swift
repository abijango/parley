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
        let cleaned = CursorAgentRunner.sanitizeNoteText(raw)
        XCTAssertTrue(cleaned.hasPrefix("## Attendees"))
    }

    func testBackendCursorModelIDs() {
        XCTAssertEqual(SummaryBackend.composer25.cursorModelID, "composer-2.5")
        XCTAssertEqual(SummaryBackend.composer25Fast.cursorModelID, "composer-2.5-fast")
        XCTAssertEqual(SummaryBackend.cursorGrok45.cursorModelID, "cursor-grok-4.5-high")
        XCTAssertEqual(SummaryBackend.cursorGrok45Fast.cursorModelID, "cursor-grok-4.5-high-fast")
        XCTAssertTrue(SummaryBackend.composer25.isCursorAgent)
        XCTAssertFalse(SummaryBackend.claude.isCursorAgent)
    }
}
