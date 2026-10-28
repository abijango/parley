import XCTest
@testable import Parley

/// Live settled history: rows older than the lock horizon never change identity or
/// text while the call runs, and the table never needs a full reload.
@MainActor
final class LiveTranscriptLockTests: XCTestCase {

    private func makeEngine() -> FluidAudioEngine {
        let engine = FluidAudioEngine(settings: .shared)
        engine.beginLiveForTesting()
        return engine
    }

    /// Simulates ~2 minutes: a 6s ASR unit cadence and 10s diarization chunks that
    /// alternate speakers, re-deriving after every event like the live publish.
    private func simulate(_ engine: FluidAudioEngine, until end: TimeInterval,
                          onTimeline: ([Segment], TimeInterval, TimeInterval) -> Void) {
        var t: TimeInterval = 0
        var diarEnd: TimeInterval = 0
        var n = 0
        while t < end {
            engine.appendConfirmedForTesting("word\(n) more\(n) words\(n)", start: t, end: t + 6)
            t += 6
            n += 1
            onTimeline(engine.confirmedTimeline(), t, diarEnd)
            if t - diarEnd >= 10 {
                let speaker = Int(diarEnd / 10) % 2 == 0 ? "1" : "2"
                engine.ingestDiarizationForTesting([(speaker, diarEnd, t)])
                diarEnd = t
                onTimeline(engine.confirmedTimeline(), t, diarEnd)
            }
        }
    }

    func testLockedRowsNeverChange() {
        let engine = makeEngine()
        var frozen: [UUID: Segment] = [:]
        simulate(engine, until: 120) { timeline, now, covered in
            for s in timeline {
                if let before = frozen[s.id] {
                    XCTAssertEqual(before.text, s.text, "locked row text changed at \(now)s")
                    XCTAssertEqual(before.speakerId, s.speakerId, "locked row speaker changed at \(now)s")
                }
            }
            // Rows that ended well before the horizon (measured from what diarization
            // has covered) are locked from here on.
            for s in timeline where s.end < covered - engine.lockHorizon - 6 && frozen[s.id] == nil {
                frozen[s.id] = s
            }
        }
        XCTAssertFalse(frozen.isEmpty, "simulation never produced a locked row")
        let finalIds = Set(engine.confirmedTimeline().map(\.id))
        XCTAssertTrue(Set(frozen.keys).isSubset(of: finalIds), "a locked row lost its identity")
    }

    func testLiveEditsNeverReloadWholeTable() {
        let engine = makeEngine()
        var previous: [Segment] = []
        simulate(engine, until: 120) { timeline, now, _ in
            // The one switch from track labels to diarized rows is a real reset.
            if previous.contains(where: { $0.speakerId != nil }) {
                XCTAssertNotEqual(LiveTranscriptTableDiff.edit(from: previous, to: timeline), .reloadAll,
                                  "full reload at \(now)s")
            }
            previous = timeline
        }
    }

    /// Diarization stalls, then catches up: lines it hadn't covered must not have been
    /// frozen with a guessed speaker.
    func testLockWaitsForDiarizationCoverage() {
        let engine = makeEngine()
        engine.ingestDiarizationForTesting([("1", 0, 20)])
        var t: TimeInterval = 0
        while t < 120 {
            engine.appendConfirmedForTesting("a b c", start: t, end: t + 6)
            t += 6
            _ = engine.confirmedTimeline()
        }
        engine.ingestDiarizationForTesting([("2", 20, 120)])
        for s in engine.confirmedTimeline() where s.start >= 24 {
            XCTAssertEqual(s.speakerId, "2", "row at \(s.start)s was frozen before diarization covered it")
        }
    }

    func testNamingRelabelsLockedRowsInPlace() {
        let engine = makeEngine()
        simulate(engine, until: 90) { _, _, _ in }
        let before = engine.confirmedTimeline()
        engine.setSpeakerName("1", as: "Alex")
        let after = engine.confirmedTimeline()
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        for (b, a) in zip(before, after) where b.speakerId == "1" {
            XCTAssertEqual(a.speakerName, "Alex")
        }
    }

    func testSameNameMergesSpeakers() {
        let engine = makeEngine()
        simulate(engine, until: 60) { _, _, _ in }
        engine.setSpeakerName("1", as: "Alex")
        engine.setSpeakerName("2", as: "alex")
        let speakers = Set(engine.confirmedTimeline().compactMap(\.speakerId))
        XCTAssertEqual(speakers.count, 1)
        XCTAssertEqual(SpeakerRoster.speakers(from: engine.confirmedTimeline()).count, 1)
    }

    func testMergeWithoutNameFoldsIntoTarget() {
        let engine = makeEngine()
        simulate(engine, until: 60) { _, _, _ in }
        engine.mergeSpeaker("2", into: "1")
        XCTAssertEqual(Set(engine.confirmedTimeline().compactMap(\.speakerId)), ["1"])
        engine.setSpeakerName("1", as: "Sam")
        XCTAssertEqual(engine.resolvedName(for: "2"), "Sam")
    }

    func testEndingLiveReleasesLock() {
        let engine = makeEngine()
        simulate(engine, until: 90) { _, _, _ in }
        engine.endLiveForTesting()
        // Whole-history re-derive still yields a full, ordered transcript.
        let timeline = engine.confirmedTimeline()
        XCTAssertFalse(timeline.isEmpty)
        XCTAssertEqual(timeline.map(\.start), timeline.map(\.start).sorted())
    }
}
