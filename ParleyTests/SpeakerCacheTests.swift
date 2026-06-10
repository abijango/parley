import XCTest
@testable import Parley

/// Covers the pure pieces behind instant speaker assignment + the roster-name cleanup:
/// transcript relabeling by substitution, cache round-trip, and stripping Teams status
/// badges from names.
final class SpeakerCacheTests: XCTestCase {

    // MARK: relabel

    func testRelabelSubstitutesSpeakerLabels() {
        let body = """
        **[00:00:00] Speaker 0:** hello
        **[00:00:05] Speaker 1:** hi there
        **[00:00:09] Speaker 0:** bye
        """
        let out = SpeakerCache.relabel(body, assignments: ["0": "Naufal Mir", "1": "Andre"])
        XCTAssertTrue(out.contains("**[00:00:00] Naufal Mir:** hello"))
        XCTAssertTrue(out.contains("**[00:00:05] Andre:** hi there"))
        XCTAssertTrue(out.contains("**[00:00:09] Naufal Mir:** bye"))
        XCTAssertFalse(out.contains("Speaker 0"))
    }

    func testRelabelDoesNotConfuseSpeaker1And10() {
        let body = "**[00:00:00] Speaker 1:** a\n**[00:00:05] Speaker 10:** b"
        let out = SpeakerCache.relabel(body, assignments: ["1": "Bob"])
        XCTAssertTrue(out.contains("**[00:00:00] Bob:** a"))
        XCTAssertTrue(out.contains("**[00:00:05] Speaker 10:** b"))   // untouched
    }

    func testRelabelLeavesUnassignedSpeakers() {
        let body = "**[00:00:00] Speaker 0:** a\n**[00:00:05] Speaker 1:** b"
        let out = SpeakerCache.relabel(body, assignments: ["0": "Naufal"])
        XCTAssertTrue(out.contains("Naufal"))
        XCTAssertTrue(out.contains("Speaker 1"))   // still unassigned
    }

    // MARK: cache round-trip

    func testCacheRoundTrips() throws {
        let cache = SpeakerCache(
            embeddingModelID: "wespeaker_v2", mixedCafName: "mixed.caf",
            speakers: [
                .init(id: "0", resolvedName: "Naufal Mir", talkSeconds: 120,
                      sampleStart: 10, sampleEnd: 18, firstLine: "hi", centroid: [0.1, 0.2, 0.3]),
                .init(id: "1", resolvedName: nil, talkSeconds: 60,
                      sampleStart: 30, sampleEnd: 38, firstLine: "yo", centroid: []),
            ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.write(to: dir)
        let back = SpeakerCache.read(dir)
        XCTAssertEqual(back, cache)
        XCTAssertEqual(back?.speakers.first?.centroid, [0.1, 0.2, 0.3])
    }

    // MARK: roster name cleanup

    func testStripStatusBadges() {
        XCTAssertEqual(MeetingParsers.stripStatusBadges("Farhang Mehregani External unfamiliar"),
                       "Farhang Mehregani")
        XCTAssertEqual(MeetingParsers.stripStatusBadges("Miguel Serrano External"), "Miguel Serrano")
        XCTAssertEqual(MeetingParsers.stripStatusBadges("Naufal Mir"), "Naufal Mir")   // clean name untouched
        XCTAssertEqual(MeetingParsers.stripStatusBadges("Farhang's Notetaker Unverified"),
                       "Farhang's Notetaker")
    }
}
