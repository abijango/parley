import XCTest
@testable import Parley

/// Edits made on a meeting awaiting review (title, attendee chips) must survive into the
/// staged summary and the next re-summary.
@MainActor
final class NeedsYouEditsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeedsYouEditsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func speaker(_ id: String, resolved: String? = nil, guess: String? = nil) -> SpeakerCache.Speaker {
        SpeakerCache.Speaker(id: id, resolvedName: resolved, guessedName: guess, talkSeconds: 10,
                             sampleStart: 0, sampleEnd: 1, firstLine: "", centroid: [])
    }

    // MARK: Rename keeps the staged summary

    func testMoveStagingCarriesEveryVariantToTheNewStem() throws {
        let staging = tmp.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let old = tmp.appendingPathComponent("2026-10-27-1629 - Meeting join - Setup.md")
        let new = tmp.appendingPathComponent("2026-10-27-1629 - Setup.md")
        let oldClaude = SummaryService.stagingURL(for: old, backend: .claude, stagingDir: staging)
        let oldV2 = SummaryService.v2StagingURL(for: old, stagingDir: staging)
        try "claude draft".write(to: oldClaude, atomically: true, encoding: .utf8)
        try "v2 draft".write(to: oldV2, atomically: true, encoding: .utf8)

        SummaryService.moveStaging(from: old, to: new, stagingDir: staging)

        XCTAssertTrue(SummaryService.allStagedSummaries(for: old, stagingDir: staging).isEmpty)
        let moved = SummaryService.allStagedSummaries(for: new, stagingDir: staging)
        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(try String(contentsOf: SummaryService.stagingURL(for: new, backend: .claude,
                                                                       stagingDir: staging), encoding: .utf8),
                       "claude draft")
        XCTAssertNotNil(SummaryService.preferredStagingURL(for: new, prefer: .claude, stagingDir: staging))
    }

    // MARK: Queued job sees later attendee edits

    func testReloadingMetaPicksUpAttendeeEditsAndKeepsDate() throws {
        let url = tmp.appendingPathComponent("2026-10-27-1629 - Setup.md")
        try """
        ---
        title: Setup
        date: 2026-10-27 16:29:59
        attendees:
          - Naufal Mir
          - Leon Melamed
        filing: Work
        status: unprocessed
        type: recording
        ---
        **[00:00:01] Naufal Mir:** hi
        """.write(to: url, atomically: true, encoding: .utf8)
        let queued = try XCTUnwrap(TranscriptWriter.parseFrontmatter(url))
        let date = Date(timeIntervalSince1970: 1_000)
        var snapshotMeta = queued
        snapshotMeta.date = date
        let snapshot = TranscriptItem(url: url, meta: snapshotMeta, isProcessed: false)

        TranscriptWriter.updateFrontmatter(at: url) { $0.attendees = ["Naufal Mir", "Chloe Troy"] }
        let fresh = SummaryService.reloadingMeta(snapshot)

        XCTAssertEqual(fresh.meta.attendees, ["Naufal Mir", "Chloe Troy"])
        XCTAssertEqual(fresh.meta.date, date)
    }

    // MARK: Attendee list is authoritative in the prompt

    func testAuthorityBlockFlagsLabelledSpeakersTheUserRemoved() throws {
        let transcript = """
        **Attendees:** Naufal Mir, Chloe Troy
        **[00:00:01] Naufal Mir:** hi
        **[00:00:04] Leon Melamed:** hello
        **[00:00:07] Speaker 2:** hey
        **[00:00:09] Me:** ok
        - [ ] Action: follow up
        """
        let block = try XCTUnwrap(SummaryPromptBuilder.attendeeAuthorityBlock(
            attendees: ["Naufal Mir", "Chloe Troy"], transcript: transcript))
        XCTAssertTrue(block.contains("exactly these people: Naufal Mir, Chloe Troy"))
        XCTAssertTrue(block.contains("misidentifications the user removed: Leon Melamed."))
        XCTAssertFalse(block.contains("Action"))
    }

    func testAuthorityBlockOmitsRemovedLineWhenEveryLabelIsListed() throws {
        let block = try XCTUnwrap(SummaryPromptBuilder.attendeeAuthorityBlock(
            attendees: ["naufal mir"], transcript: "**[00:00:01] Naufal Mir:** hi"))
        XCTAssertFalse(block.contains("misidentifications"))
        XCTAssertNil(SummaryPromptBuilder.attendeeAuthorityBlock(attendees: [], transcript: ""))
    }

    func testSpeakerLabelsSkipsGenericLabels() {
        let labels = SummaryPromptBuilder.speakerLabels(in: """
        **[00:00:01] Naufal Mir:** a
        **[00:00:02] Remote:** b
        **[00:00:03] Speaker 10:** c
        **[00:00:04] naufal mir:** d
        **[00:00:05] Chloe Troy:** e
        """)
        XCTAssertEqual(labels, ["Naufal Mir", "Chloe Troy"])
    }

    // MARK: Removing a chip un-names that speaker

    func testUnassignRelabelsTheRemovedSpeakerAndClearsSuggestions() {
        var cache = SpeakerCache(embeddingModelID: "m", mixedCafName: "mixed.caf", speakers: [
            speaker("0", resolved: "Naufal Mir"),
            speaker("1", resolved: "Leon Melamed"),
            speaker("2", guess: "Leon Melamed"),
        ])
        let body = """
        **[00:00:01] Naufal Mir:** hi
        **[00:00:04] Leon Melamed:** hello
        **[00:00:08] Speaker 2:** hey
        """
        let out = SpeakerCache.unassign(["leon melamed"], in: &cache, body: body)

        XCTAssertTrue(out.contains("**[00:00:04] Speaker 1:** hello"))
        XCTAssertTrue(out.contains("**[00:00:01] Naufal Mir:** hi"))
        XCTAssertNil(cache.speakers[1].resolvedName)
        XCTAssertNil(cache.speakers[2].guessedName)
        XCTAssertEqual(cache.speakers[0].resolvedName, "Naufal Mir")
    }

    func testUnassignLeavesANameSharedBySeveralSpeakers() {
        var cache = SpeakerCache(embeddingModelID: "m", mixedCafName: "mixed.caf", speakers: [
            speaker("0", resolved: "Leon Melamed"),
            speaker("1", resolved: "Leon Melamed"),
        ])
        let body = "**[00:00:04] Leon Melamed:** hello"
        let out = SpeakerCache.unassign(["Leon Melamed"], in: &cache, body: body)
        XCTAssertEqual(out, body)
        XCTAssertEqual(cache.speakers.compactMap(\.resolvedName).count, 2)
    }
}
