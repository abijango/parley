import XCTest
@testable import Parley

/// Covers `TranscriptStitcher.stitch` — the pure C1 transcript-stitch implementation.
final class TranscriptStitcherTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a minimal but structurally valid Parley note string with the given
    /// parameters.  The result mirrors what `TranscriptWriter.makeBody` emits, so
    /// `TranscriptWriter.parseFrontmatter(text:)` and
    /// `TranscriptWriter.extractBodySections(text:)` can round-trip it.
    private func makeNote(
        title: String = "Stand-up",
        date: String = "2026-06-25 10:00:00",
        filing: String = "Engineering",
        attendees: [String] = ["Alice", "Bob"],
        transcriptLines: [String] = [],
        manualNotes: String? = nil
    ) -> String {
        var lines: [String] = []

        // YAML frontmatter
        lines.append("---")
        lines.append("title: \(title)")
        lines.append("date: \(date)")
        if attendees.isEmpty {
            lines.append("attendees: []")
        } else {
            lines.append("attendees:")
            for a in attendees { lines.append("  - \(a)") }
        }
        lines.append("filing: \(filing)")
        lines.append("status: unprocessed")
        lines.append("type: recording")
        lines.append("---")

        // Human-readable header
        lines.append("# \(title)")
        lines.append("")
        var header = ["**Date:** 2026-06-25"]
        if !filing.isEmpty { header.append("**Filing:** \(filing)") }
        if !attendees.isEmpty { header.append("**Attendees:** \(attendees.joined(separator: ", "))") }
        lines.append(header.joined(separator: "  \n"))
        lines.append("")

        // Optional manual notes
        if let notes = manualNotes, !notes.isEmpty {
            lines.append("## Notes (manual)")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        // Transcript section
        lines.append("## Transcript")
        lines.append("")
        if !transcriptLines.isEmpty {
            lines.append(transcriptLines.joined(separator: "\n\n"))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Single-note passthrough

    /// A single note must be returned byte-for-byte unchanged (no parse/re-emit).
    func testSingleNoteReturnedVerbatim() {
        let note = makeNote(transcriptLines: ["**[00:01:30] Alice:** hello"])
        let result = TranscriptStitcher.stitch(notes: [note], durations: [90])
        XCTAssertEqual(result, note)
    }

    func testEmptyNotesArrayReturnsEmpty() {
        let result = TranscriptStitcher.stitch(notes: [], durations: [])
        XCTAssertEqual(result, "")
    }

    // MARK: - Two-leg timestamp re-timing

    /// Leg 1's timestamps must be shifted forward by leg 0's duration.
    /// e.g. leg 0 lasts 600 s (10 min); leg 1's [00:00:05] becomes [00:10:05].
    func testTwoLegTimestampShift() {
        let leg0 = makeNote(
            attendees: ["Alice", "Bob"],
            transcriptLines: [
                "**[00:00:00] Alice:** opening",
                "**[00:05:00] Bob:** mid-point"
            ]
        )
        let leg1 = makeNote(
            attendees: ["Alice", "Bob"],
            transcriptLines: [
                "**[00:00:05] Alice:** reconnected",
                "**[00:02:30] Bob:** wrapping up"
            ]
        )
        let durations: [TimeInterval] = [600, 300]  // leg 0 = 10 min
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: durations)

        // Leg 0 timestamps stay unchanged.
        XCTAssertTrue(result.contains("[00:00:00]"), "Leg 0 start timestamp must be unchanged")
        XCTAssertTrue(result.contains("[00:05:00]"), "Leg 0 mid timestamp must be unchanged")

        // Leg 1 timestamps shifted by 600 s (= 10 min).
        // [00:00:05] + 600 = [00:10:05]
        XCTAssertTrue(result.contains("[00:10:05]"),
                      "Leg 1 first timestamp [00:00:05] must shift to [00:10:05]")
        // [00:02:30] + 600 = [00:12:30]
        XCTAssertTrue(result.contains("[00:12:30]"),
                      "Leg 1 second timestamp [00:02:30] must shift to [00:12:30]")

        // Original leg 1 raw timestamps must NOT appear.
        XCTAssertFalse(result.contains("[00:00:05]"),
                       "Leg 1 raw [00:00:05] must be gone after shift")
        XCTAssertFalse(result.contains("[00:02:30]"),
                       "Leg 1 raw [00:02:30] must be gone after shift")
    }

    /// Bold markers and speaker labels must be preserved exactly across a shift.
    func testShiftPreservesMarkdownFormatting() {
        let leg0 = makeNote(
            attendees: ["Alice"],
            transcriptLines: ["**[00:00:00] Alice:** first"]
        )
        let leg1 = makeNote(
            attendees: ["Alice"],
            transcriptLines: ["**[00:00:10] Alice:** second line with **bold** inside"]
        )
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [120, 60])

        // [00:00:10] + 120 = [00:02:10]
        XCTAssertTrue(result.contains("**[00:02:10] Alice:** second line with **bold** inside"),
                      "Bold markers and trailing text must survive the shift unchanged")
    }

    // MARK: - Three-leg running offset

    /// With three legs the offsets accumulate correctly.
    /// leg 0: 300 s, leg 1: 180 s, leg 2 shifts by 300+180=480 s.
    func testThreeLegRunningOffset() {
        let leg0 = makeNote(
            attendees: ["Alice"],
            transcriptLines: ["**[00:00:00] Alice:** leg zero"]
        )
        let leg1 = makeNote(
            attendees: ["Alice"],
            transcriptLines: ["**[00:00:00] Alice:** leg one"]
        )
        let leg2 = makeNote(
            attendees: ["Alice"],
            transcriptLines: ["**[00:00:00] Alice:** leg two"]
        )
        let durations: [TimeInterval] = [300, 180, 120]
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1, leg2], durations: durations)

        // Leg 1 shift = 300 s = 5 min → [00:05:00]
        // Leg 2 shift = 480 s = 8 min → [00:08:00]
        let occurrences = result.components(separatedBy: "[00:00:00]").count - 1
        XCTAssertEqual(occurrences, 1, "Only leg 0's [00:00:00] should remain; legs 1 & 2 must shift")
        XCTAssertTrue(result.contains("[00:05:00]"), "Leg 1 must shift to [00:05:00]")
        XCTAssertTrue(result.contains("[00:08:00]"), "Leg 2 must shift to [00:08:00]")
    }

    // MARK: - Seam markers

    /// Two legs must produce exactly one seam marker.
    func testTwoLegProducesOneSeamMarker() {
        let seam = "**\u{2014} reconnected \u{2014}**"
        let leg0 = makeNote(transcriptLines: ["**[00:00:00] Alice:** a"])
        let leg1 = makeNote(transcriptLines: ["**[00:00:00] Alice:** b"])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        let parts = result.components(separatedBy: seam)
        XCTAssertEqual(parts.count, 2,
                       "Two legs must produce exactly one seam marker; got \(parts.count - 1)")
    }

    /// Three legs must produce exactly two seam markers.
    func testThreeLegProducesTwoSeamMarkers() {
        let seam = "**\u{2014} reconnected \u{2014}**"
        let leg0 = makeNote(transcriptLines: ["**[00:00:00] Alice:** a"])
        let leg1 = makeNote(transcriptLines: ["**[00:00:00] Alice:** b"])
        let leg2 = makeNote(transcriptLines: ["**[00:00:00] Alice:** c"])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1, leg2], durations: [60, 60, 60])

        let parts = result.components(separatedBy: seam)
        XCTAssertEqual(parts.count, 3,
                       "Three legs must produce exactly two seam markers; got \(parts.count - 1)")
    }

    /// The seam marker must be surrounded by blank lines on both sides.
    func testSeamMarkerHasSurroundingBlankLines() {
        let seam = "**\u{2014} reconnected \u{2014}**"
        let leg0 = makeNote(transcriptLines: ["**[00:00:00] Alice:** before"])
        let leg1 = makeNote(transcriptLines: ["**[00:00:10] Alice:** after"])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [120, 60])

        XCTAssertTrue(result.contains("\n\n\(seam)\n\n"),
                      "Seam marker must be surrounded by blank lines (\\n\\n on each side)")
    }

    // MARK: - Attendee union

    /// The attendee union must be order-preserving (note[0] first) and case-insensitive.
    func testAttendeeUnionOrderPreserving() {
        let leg0 = makeNote(attendees: ["Alice", "Bob"], transcriptLines: [])
        let leg1 = makeNote(attendees: ["bob", "Carol"], transcriptLines: [])  // "bob" is a dupe
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        // "Carol" must appear (new in leg 1); "bob" (lowercase dupe) must NOT add a second entry.
        let lines = result.components(separatedBy: "\n")
        let attendeeYAMLLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }

        // Expect exactly 3 unique attendees: Alice, Bob, Carol.
        XCTAssertEqual(attendeeYAMLLines.count, 3,
                       "Union must have 3 entries (Alice, Bob, Carol); got: \(attendeeYAMLLines)")

        // Order: Alice before Bob before Carol.
        let aliceIdx = attendeeYAMLLines.firstIndex(where: { $0.contains("Alice") }) ?? Int.max
        let bobIdx   = attendeeYAMLLines.firstIndex(where: { $0.contains("Bob") })   ?? Int.max
        let carolIdx = attendeeYAMLLines.firstIndex(where: { $0.contains("Carol") }) ?? Int.max
        XCTAssertLessThan(aliceIdx, bobIdx,   "Alice must come before Bob in YAML attendees")
        XCTAssertLessThan(bobIdx,   carolIdx, "Bob must come before Carol in YAML attendees")
    }

    /// The `**Attendees:**` body line must also reflect the union.
    func testAttendeeUnionReflectedInBodyHeader() {
        let leg0 = makeNote(attendees: ["Alice"], transcriptLines: [])
        let leg1 = makeNote(attendees: ["Bob"],   transcriptLines: [])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        XCTAssertTrue(result.contains("**Attendees:** Alice, Bob"),
                      "Body **Attendees:** line must list all union members")
    }

    /// The YAML frontmatter attendee list must also contain all union members.
    func testAttendeeUnionReflectedInFrontmatter() {
        let leg0 = makeNote(attendees: ["Alice"], transcriptLines: [])
        let leg1 = makeNote(attendees: ["Bob"],   transcriptLines: [])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        guard let meta = TranscriptWriter.parseFrontmatter(text: result) else {
            XCTFail("Output has no parseable frontmatter"); return
        }
        XCTAssertEqual(Set(meta.attendees), Set(["Alice", "Bob"]),
                       "Frontmatter attendees must be the full union")
    }

    // MARK: - Manual notes preservation

    /// note[0]'s manual notes must appear in the output; later legs' manual notes are dropped.
    func testManualNotesFromLeg0Preserved() {
        let leg0 = makeNote(
            transcriptLines: ["**[00:00:00] Alice:** hello"],
            manualNotes: "Action: follow up with Bob"
        )
        let leg1 = makeNote(
            transcriptLines: ["**[00:00:00] Alice:** bye"],
            manualNotes: "This note should be discarded"
        )
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        XCTAssertTrue(result.contains("Action: follow up with Bob"),
                      "Leg 0's manual notes must be kept in the output")
        XCTAssertFalse(result.contains("This note should be discarded"),
                       "Later legs' manual notes must be dropped")
    }

    // MARK: - Structure validity

    /// The output must contain exactly one `## Transcript` header.
    func testOutputHasExactlyOneTranscriptHeader() {
        let leg0 = makeNote(transcriptLines: ["**[00:00:00] Alice:** a"])
        let leg1 = makeNote(transcriptLines: ["**[00:00:00] Alice:** b"])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        let count = result.components(separatedBy: "## Transcript").count - 1
        XCTAssertEqual(count, 1, "Output must have exactly one ## Transcript header")
    }

    /// The output must end with a single newline (matches TranscriptWriter.makeBody convention).
    func testOutputEndsWithSingleNewline() {
        let leg0 = makeNote(transcriptLines: ["**[00:00:00] Alice:** a"])
        let leg1 = makeNote(transcriptLines: ["**[00:00:05] Alice:** b"])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        XCTAssertTrue(result.hasSuffix("\n"), "Output must end with a newline")
        XCTAssertFalse(result.hasSuffix("\n\n"), "Output must not end with two newlines")
    }

    /// note[0]'s title, date, and filing are preserved (not replaced by later legs').
    func testBaseMetaPreserved() {
        let leg0 = makeNote(title: "Sprint Review",  filing: "Engineering", transcriptLines: [])
        let leg1 = makeNote(title: "Random Meeting", filing: "Sales",       transcriptLines: [])
        let result = TranscriptStitcher.stitch(notes: [leg0, leg1], durations: [60, 60])

        guard let meta = TranscriptWriter.parseFrontmatter(text: result) else {
            XCTFail("Output has no parseable frontmatter"); return
        }
        XCTAssertEqual(meta.title,  "Sprint Review", "Title must come from note[0]")
        XCTAssertEqual(meta.filing, "Engineering",   "Filing must come from note[0]")
    }
}
