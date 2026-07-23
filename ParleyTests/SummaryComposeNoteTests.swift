import XCTest
@testable import Parley

final class SummaryComposeNoteTests: XCTestCase {

    private func sampleItem() -> TranscriptItem {
        let meta = TranscriptMeta(
            title: "Stand-up",
            date: Date(timeIntervalSince1970: 1_774_771_200), // 2026-04-01 roughly
            attendees: ["Alice", "Bob"],
            filing: "Engineering",
            status: "unprocessed",
            note: nil,
            audio: nil,
            type: "recording"
        )
        return TranscriptItem(
            url: URL(fileURLWithPath: "/tmp/2026-04-01-1000 - Stand-up.md"),
            meta: meta,
            isProcessed: false
        )
    }

    private let transcriptSource = """
    ---
    title: Stand-up
    ---

    # Stand-up

    **Date:** 2026-04-01

    ## Notes (manual)

    Bring snacks.

    ## Transcript

    **[00:00:01] Alice:** hello

    **[00:00:05] Bob:** hi there
    """

    func testComposeAppendsRawTranscript() {
        let body = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Acme |

        ## Executive Summary
        Quick sync.
        """
        let note = SummaryService.composeNote(
            item: sampleItem(), destination: "Engineering",
            body: body, transcriptSource: transcriptSource)

        XCTAssertTrue(note.contains("source: parley-summary"))
        XCTAssertTrue(note.contains("## Executive Summary"))
        XCTAssertTrue(note.contains("## Raw Transcript"))
        XCTAssertTrue(note.contains("**[00:00:01] Alice:** hello"))
        XCTAssertTrue(note.contains("### Notes (manual)"))
        XCTAssertTrue(note.contains("Bring snacks."))
        XCTAssertFalse(note.contains("**Raw transcript:** [["))
    }

    func testComposeStripsExistingRawSectionIdempotently() {
        let body = """
        ## Executive Summary
        Once.

        ---

        ## Raw Transcript

        **[00:00:00] Old:** stale
        """
        let note = SummaryService.composeNote(
            item: sampleItem(), destination: "",
            body: body, transcriptSource: transcriptSource)

        let count = note.components(separatedBy: "## Raw Transcript").count - 1
        XCTAssertEqual(count, 1)
        XCTAssertTrue(note.contains("**[00:00:01] Alice:** hello"))
        XCTAssertFalse(note.contains("stale"))
    }

    func testStripReasoningRemovesThinkBlock() {
        let raw = "<think>planning…</think>\n\n## Attendees\n\n| Name | Role | Company |\n"
        let cleaned = QwenLocalSummaryEngine.stripReasoning(raw)
        XCTAssertFalse(cleaned.contains("<think>"))
        XCTAssertTrue(cleaned.hasPrefix("## Attendees"))
    }

    func testInferredParserIgnoresTrailingRawTranscript() {
        let markdown = """
        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Dana Lee | Sales | Acme (inferred) |

        ## Executive Summary
        Hello.

        ---

        ## Raw Transcript

        **[00:00:01] Dana Lee:** I'm from Acme
        """
        let result = InferredAffiliationParser.parseInferred(markdown: markdown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Dana Lee")
        XCTAssertEqual(result[0].company, "Acme")
    }
}
