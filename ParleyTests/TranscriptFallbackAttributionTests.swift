import XCTest
@testable import Parley

/// Covers the pure fallback-attribution helper used when the offline ASR pass fails the
/// coverage gate but diarization succeeded: `TranscriptFallbackAttribution.relabel`.
final class TranscriptFallbackAttributionTests: XCTestCase {

    // MARK: helpers

    private func turn(_ id: String, start: TimeInterval, end: TimeInterval) -> DiarizationAttribution.Turn {
        DiarizationAttribution.Turn(speakerId: id, start: start, end: end)
    }

    // MARK: generic labels are relabeled

    func testRelabelsRemoteLabel() {
        let body = """
        **[00:00:00] Remote:** hello there
        **[00:00:10] Remote:** how are you
        """
        let turns = [turn("1", start: 0, end: 8), turn("2", start: 8, end: 20)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { id in id == "1" ? "Alice" : "Bob" }
        )
        XCTAssertEqual(changed, 2)
        XCTAssertTrue(out.contains("**[00:00:00] Alice:** hello there"))
        XCTAssertTrue(out.contains("**[00:00:10] Bob:** how are you"))
        XCTAssertFalse(out.contains("] Remote:"))
    }

    func testRelabelsMeLabel() {
        let body = "**[00:00:05] Me:** speaking here"
        let turns = [turn("0", start: 0, end: 15)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in "Naufal Mir" }
        )
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(out.contains("**[00:00:05] Naufal Mir:** speaking here"))
        XCTAssertFalse(out.contains("] Me:"))
    }

    func testRelabelsSpeakerNLabel() {
        let body = "**[00:01:00] Speaker 3:** hi"
        let turns = [turn("2", start: 55, end: 70)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in "Carol" }
        )
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(out.contains("**[00:01:00] Carol:** hi"))
    }

    // MARK: unresolved speakers become "Speaker <id>"

    func testUnresolvedSpeakerFallsBackToSpeakerId() {
        let body = "**[00:00:00] Remote:** something"
        let turns = [turn("3", start: 0, end: 10)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in nil }   // no name resolved
        )
        XCTAssertEqual(changed, 1)
        // Must use "Speaker <id>" so SpeakerCache.relabel can substitute it later.
        XCTAssertTrue(out.contains("**[00:00:00] Speaker 3:** something"))
    }

    // MARK: named lines are untouched

    func testNamedLinesAreNotRelabeled() {
        let body = """
        **[00:00:00] Alice:** already named
        **[00:00:10] Remote:** generic line
        """
        let turns = [turn("1", start: 0, end: 20)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in "Bob" }
        )
        XCTAssertEqual(changed, 1, "Only the generic line should change")
        XCTAssertTrue(out.contains("**[00:00:00] Alice:** already named"))
        XCTAssertTrue(out.contains("**[00:00:10] Bob:** generic line"))
    }

    // MARK: non-transcript lines are untouched

    func testFrontmatterAndHeadingsAreUntouched() {
        let body = """
        ---
        title: Test Meeting
        date: 2026-06-09 10:00:00
        ---

        # Test Meeting

        **Date:** 2026-06-09

        ## Transcript

        **[00:00:00] Remote:** first line
        """
        let turns = [turn("1", start: 0, end: 10)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in "Alice" }
        )
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(out.contains("---"))
        XCTAssertTrue(out.contains("# Test Meeting"))
        XCTAssertTrue(out.contains("## Transcript"))
        XCTAssertTrue(out.contains("**[00:00:00] Alice:** first line"))
    }

    // MARK: Speaker 1 vs Speaker 10 disambiguation

    func testSpeaker1DoesNotMatchSpeaker10() {
        // "Speaker 10" must not be rewritten when only "Speaker 1" is a generic label.
        // The relabeler uses the full label up to the colon so "Speaker 1" ≠ "Speaker 10".
        let body = """
        **[00:00:00] Speaker 1:** line a
        **[00:00:10] Speaker 10:** line b
        """
        // Two distinct turns — one covers [0,8], the other [8,20].
        let turns = [turn("5", start: 0, end: 8), turn("6", start: 8, end: 20)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in nil }   // unresolved → "Speaker <id>"
        )
        // Both "Speaker 1" and "Speaker 10" are generic labels, so both are rewritten.
        XCTAssertEqual(changed, 2)
        // The rewritten labels must not mix up the two original labels.
        XCTAssertFalse(out.contains("] Speaker 1:"), "Speaker 1 should have been relabeled")
        XCTAssertFalse(out.contains("] Speaker 10:"), "Speaker 10 should have been relabeled")
        // Verify the new labels use the correct speaker ids, not the old numeric ids.
        XCTAssertTrue(out.contains("] Speaker 5:") || out.contains("] Speaker 6:"))
    }

    func testSpeaker1LabelNotPartialMatchForSpeaker10AfterRelabel() {
        // When Speaker 1 resolves to a real name and Speaker 10 is unresolved:
        // the substitution of "Speaker 1" → "Alice" must not corrupt "Speaker 10".
        // "Speaker 10" unresolved → falls back to "Speaker 10" (same as original) → 0 change.
        let body = """
        **[00:00:00] Speaker 1:** line a
        **[00:00:10] Speaker 10:** line b
        """
        let turns = [turn("1", start: 0, end: 8), turn("10", start: 8, end: 20)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { id in id == "1" ? "Alice" : nil }
        )
        // Only "Speaker 1" changes; "Speaker 10" → fallback "Speaker 10" is same → no change.
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(out.contains("**[00:00:00] Alice:** line a"))
        XCTAssertTrue(out.contains("**[00:00:10] Speaker 10:** line b"), "Speaker 10 must remain intact")
        // Safety: the "Speaker 1" → "Alice" substitution must never corrupt "Speaker 10".
        XCTAssertFalse(out.contains("Alicer"), "Speaker 10 must not be partially overwritten")
        XCTAssertFalse(out.contains("Alice0:"), "Speaker 10 must not become 'Alice0'")
    }

    // MARK: empty turns → zero changes

    func testEmptyTurnsReturnsUnchanged() {
        let body = "**[00:00:00] Remote:** hi"
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: [],
            resolvedName: { _ in "Alice" }
        )
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(out, body)
    }

    // MARK: midpoint attribution picks the containing turn

    func testMidpointAttributionPicksContainingTurn() {
        // Line at [00:00:00], next line at [00:00:20] → end = 20, mid = 10.
        // Turn "A" covers 0–8, turn "B" covers 8–25. Mid=10 is inside turn "B".
        let body = """
        **[00:00:00] Remote:** first
        **[00:00:20] Remote:** second
        """
        let turns = [turn("A", start: 0, end: 8), turn("B", start: 8, end: 25)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { id in id == "A" ? "Alice" : "Bob" }
        )
        XCTAssertEqual(changed, 2)
        // First line: start=0, end=20, mid=10 → inside turn B → "Bob"
        XCTAssertTrue(out.contains("**[00:00:00] Bob:** first"),
                      "Mid=10 falls in turn B [8,25], so label should be Bob")
        // Second line: start=20, end=35 (20+15, no next line), mid=27.5 → nearest to turn B
        XCTAssertTrue(out.contains("**[00:00:20] Bob:** second"))
    }

    func testLastLineFallsBackTo15SecondWindow() {
        // Last timestamped line gets a 15-second window (start … start+15), so mid = start+7.5.
        // A turn covering [0, 15] should pick up that line.
        let body = "**[00:00:05] Me:** only line"
        let turns = [turn("X", start: 0, end: 15)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in "Zara" }
        )
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(out.contains("**[00:00:05] Zara:** only line"))
    }

    // MARK: unbolded variant also handled

    func testUnboldedTimestampLineIsRelabeled() {
        let body = "[00:00:00] Remote: hello"
        let turns = [turn("1", start: 0, end: 10)]
        let (out, changed) = TranscriptFallbackAttribution.relabel(
            body: body,
            turns: turns,
            resolvedName: { _ in "Alice" }
        )
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(out.contains("[00:00:00] Alice: hello"))
    }
}
