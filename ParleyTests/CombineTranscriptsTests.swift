import XCTest
@testable import Parley

/// Covers the pure body-stitching used by History's "Combine" feature: pulling the
/// transcript / manual-notes sections back out of a written note, and re-emitting
/// several as one cohesive document.
final class CombineTranscriptsTests: XCTestCase {

    private func date(_ s: String) -> Date {
        TranscriptWriter.parseISODate(s)!
    }

    // MARK: extractBodySections

    func testExtractsTranscriptAfterHeader() {
        let text = """
        ---
        title: A
        ---
        # A

        **Date:** 2026-06-08

        ## Transcript

        **[00:00:00] Me:** hello

        **[00:00:05] Remote:** hi
        """
        let (notes, transcript) = TranscriptWriter.extractBodySections(text: text)
        XCTAssertNil(notes)
        XCTAssertTrue(transcript.hasPrefix("**[00:00:00] Me:** hello"))
        XCTAssertTrue(transcript.contains("**[00:00:05] Remote:** hi"))
        // The "## Transcript" header itself must not leak into the extracted body.
        XCTAssertFalse(transcript.contains("## Transcript"))
    }

    func testExtractsManualNotesBoundedByNextHeader() {
        let text = """
        ---
        title: A
        ---
        # A

        ## Notes (manual)

        remember to follow up

        ## Transcript

        **[00:00:00] Me:** hello
        """
        let (notes, transcript) = TranscriptWriter.extractBodySections(text: text)
        XCTAssertEqual(notes, "remember to follow up")
        XCTAssertEqual(transcript, "**[00:00:00] Me:** hello")
    }

    func testNoTranscriptHeaderYieldsEmptyTranscript() {
        let text = """
        ---
        title: A
        ---
        # A

        ## Notes

        just a manual note
        """
        let (notes, transcript) = TranscriptWriter.extractBodySections(text: text)
        XCTAssertEqual(notes, "just a manual note")
        XCTAssertTrue(transcript.isEmpty)
    }

    // MARK: makeCombinedBody

    func testCombinedBodyHasFrontmatterAndOrderedParts() {
        let meta = TranscriptMeta(title: "Big Call", date: date("2026-06-08 13:00:00"),
                                  attendees: ["Naufal Mir", "Andre Nedelcoux"], filing: "Internal",
                                  status: "unprocessed", note: nil, audio: nil, type: "recording")
        let parts = [
            TranscriptWriter.CombinePart(title: "Part one", date: date("2026-06-08 13:00:00"),
                                         manualNotes: nil, transcript: "**[00:00:00] Me:** first"),
            TranscriptWriter.CombinePart(title: "Part two", date: date("2026-06-08 14:30:00"),
                                         manualNotes: nil, transcript: "**[00:00:00] Me:** second"),
        ]
        let body = TranscriptWriter.makeCombinedBody(meta: meta, parts: parts)

        // Round-trips through the frontmatter parser with merged metadata intact.
        let parsed = TranscriptWriter.parseFrontmatter(text: body)
        XCTAssertEqual(parsed?.title, "Big Call")
        XCTAssertEqual(parsed?.attendees, ["Naufal Mir", "Andre Nedelcoux"])
        XCTAssertNil(parsed?.audio)   // combined notes intentionally carry no single audio link

        // Both parts present, in order, each under its own dated header.
        XCTAssertTrue(body.contains("### Part 1: Part one — 2026-06-08 13:00"))
        XCTAssertTrue(body.contains("### Part 2: Part two — 2026-06-08 14:30"))
        let firstRange = body.range(of: "first")!
        let secondRange = body.range(of: "second")!
        XCTAssertTrue(firstRange.lowerBound < secondRange.lowerBound, "Parts must keep chronological order")
    }

    func testCombinedBodyGathersManualNotes() {
        let meta = TranscriptMeta(title: "C", date: date("2026-06-08 13:00:00"),
                                  attendees: [], filing: "", status: "unprocessed",
                                  note: nil, audio: nil, type: "recording")
        let parts = [
            TranscriptWriter.CombinePart(title: "P1", date: date("2026-06-08 13:00:00"),
                                         manualNotes: "note A", transcript: "**[00:00:00] Me:** x"),
            TranscriptWriter.CombinePart(title: "P2", date: date("2026-06-08 13:10:00"),
                                         manualNotes: nil, transcript: "**[00:00:00] Me:** y"),
        ]
        let body = TranscriptWriter.makeCombinedBody(meta: meta, parts: parts)
        XCTAssertTrue(body.contains("## Notes (manual)"))
        XCTAssertTrue(body.contains("note A"))
    }
}
