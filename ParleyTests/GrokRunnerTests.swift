import XCTest
@testable import Parley

final class GrokRunnerTests: XCTestCase {

    func testParseJSONSuccessText() {
        let json = """
        {"text":"# Hello\\n\\nBody","stopReason":"EndTurn","sessionId":"abc"}
        """
        switch GrokRunner.parseJSONResult(stdout: json) {
        case .text(let t):
            XCTAssertTrue(t.hasPrefix("# Hello"))
            XCTAssertTrue(t.contains("Body"))
        default:
            XCTFail("expected .text")
        }
    }

    func testParseJSONErrorObject() {
        let json = """
        {"type":"error","message":"Couldn't start session: not logged in"}
        """
        switch GrokRunner.parseJSONResult(stdout: json) {
        case .error(let msg):
            XCTAssertTrue(msg.lowercased().contains("not logged in"))
        default:
            XCTFail("expected .error")
        }
    }

    func testParseJSONEmptyTextIsUnparseable() {
        let json = #"{"text":"   ","stopReason":"EndTurn"}"#
        if case .unparseable = GrokRunner.parseJSONResult(stdout: json) {
            // ok
        } else {
            XCTFail("empty text should be unparseable")
        }
    }

    func testParseJSONGarbage() {
        if case .unparseable = GrokRunner.parseJSONResult(stdout: "not json at all") {
            // ok
        } else {
            XCTFail("expected unparseable")
        }
    }

    func testSanitizeNoteTextStripsAgentPreamble() {
        let raw = """
        Looking for the full transcript to fill in truncated sections.\
        Searching for the complete transcript.Found it. Reading in full.

        ## Attendees

        | Name | Role | Company |
        """
        let cleaned = GrokRunner.sanitizeNoteText(raw)
        XCTAssertTrue(cleaned.hasPrefix("## Attendees"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("Looking for"))
    }

    func testSanitizeNoteTextPassthroughWhenNoMarker() {
        let raw = "# Title\n\nSome body."
        XCTAssertEqual(GrokRunner.sanitizeNoteText(raw), raw)
    }

    func testMakeProcessRejectsMissingBinary() {
        XCTAssertThrowsError(
            try GrokRunner.makeRawSummaryProcess(
                binaryPath: "/tmp/definitely-no-grok-\(UUID().uuidString)",
                prompt: "hi",
                model: "grok-4.5")
        ) { err in
            guard let e = err as? GrokRunner.RunError, case .binaryNotFound = e else {
                return XCTFail("expected binaryNotFound, got \(err)")
            }
        }
    }
}
