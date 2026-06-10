import XCTest
@testable import Parley

/// Unit tests for `JobProgressRelay`: throttling correctness, stage-change flushing,
/// min(asr,diar) semantics, and thread-safety smoke.
final class JobProgressRelayTests: XCTestCase {

    // MARK: Throttle — a burst of 100 .asr events yields ≤ a handful of publishes

    func testBurstOfAsrEventsIsThrottled() {
        // Ceiling: ceil(window / 0.2) + 2 publishes (one immediate on first non-nil signal,
        // one deferred at end of window, plus a couple of slack for scheduling jitter).
        let windowSec = 0.6
        let maxExpected = Int(ceil(windowSec / 0.2)) + 2   // = 5

        var publishCount = 0
        let relay = JobProgressRelay(jobID: "test") { _, _ in publishCount += 1 }

        // Seed the transcribeAndDiarize stage so asr events hit the right branch.
        relay.set(stage: .transcribeAndDiarize, fraction: nil, sublabel: nil)

        let deadline = Date(timeIntervalSinceNow: windowSec)
        var i = 0
        while Date() < deadline {
            relay.report(.asr(Double(i % 100) / 100.0))
            i += 1
            // Small spin so we actually produce 100+ events; not a tight busy-loop.
            if i % 10 == 0 { Thread.sleep(forTimeInterval: 0.001) }
        }

        // Wait for any in-flight deferred publishes to drain.
        let drainExpectation = expectation(description: "deferred drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            drainExpectation.fulfill()
        }
        wait(for: [drainExpectation], timeout: 2)

        XCTAssertLessThanOrEqual(publishCount, maxExpected,
            "Expected ≤\(maxExpected) publishes for a \(Int(windowSec * 1000)) ms burst, got \(publishCount)")
    }

    // MARK: Stage change publishes immediately

    func testStageChangePublishesImmediately() {
        var published: [JobProgress.Stage] = []
        let expectMix = expectation(description: "mix published")
        let expectTranscribe = expectation(description: "transcribe published")
        expectMix.assertForOverFulfill = false
        expectTranscribe.assertForOverFulfill = false

        let relay = JobProgressRelay(jobID: "stagetest") { _, snap in
            published.append(snap.stage)
            if snap.stage == .mix { expectMix.fulfill() }
            if snap.stage == .transcribeAndDiarize { expectTranscribe.fulfill() }
        }

        relay.set(stage: .mix, fraction: nil, sublabel: nil)
        relay.report(.mixDone)  // relay advances internally to .transcribeAndDiarize

        wait(for: [expectMix, expectTranscribe], timeout: 1)
        XCTAssertTrue(published.contains(.mix))
        XCTAssertTrue(published.contains(.transcribeAndDiarize))
    }

    // MARK: min(asr, diar) semantics

    func testFractionIsMinOfAsrAndDiar() {
        // After both sides have reported, the bar fill must be min(asr, diar).
        // Signal done on both sides so the relay knows both fractions are final.
        var lastSnap: JobProgress?
        let exp = expectation(description: "both done published")
        exp.assertForOverFulfill = false

        let relay = JobProgressRelay(jobID: "mintest") { _, snap in
            lastSnap = snap
            // The sublabel contains both sides once both have reported.
            if snap.sublabel?.contains("·") == true { exp.fulfill() }
        }
        relay.set(stage: .transcribeAndDiarize, fraction: nil, sublabel: nil)
        relay.report(.asr(0.8))
        relay.report(.diarization(0.5))

        wait(for: [exp], timeout: 1)

        // Fraction = min(0.8, 0.5) = 0.5 once both sides have reported.
        if let f = lastSnap?.fraction {
            XCTAssertEqual(f, 0.5, accuracy: 0.01,
                "fraction should be min(asr=0.8, diar=0.5) = 0.5, got \(f)")
        } else {
            XCTFail("Expected a non-nil fraction after both sides reported")
        }
    }

    func testDoneSideCountsAs1() {
        // When diarization signals Done before ASR finishes, diar counts as 1.0 so
        // the fraction becomes min(asr, 1.0) = asr, and the bar can advance.
        var lastSnap: JobProgress?
        let exp = expectation(description: "fraction with done side")
        exp.assertForOverFulfill = false

        let relay = JobProgressRelay(jobID: "donetest") { _, snap in
            if snap.fraction != nil { lastSnap = snap; exp.fulfill() }
        }
        relay.set(stage: .transcribeAndDiarize, fraction: nil, sublabel: nil)
        relay.report(.diarizationDone)   // diar now counts as 1.0
        relay.report(.asr(0.6))          // asr at 60%

        wait(for: [exp], timeout: 1)
        // fraction = min(0.6, 1.0) = 0.6
        if let f = lastSnap?.fraction {
            XCTAssertEqual(f, 0.6, accuracy: 0.01,
                "With diar=Done(1.0) and asr=0.6, fraction should be 0.6, got \(f)")
        } else {
            XCTFail("Expected non-nil fraction")
        }
    }

    func testAsrDoneAloneSetsSubLabel() {
        // Before diar reports anything, asrDone alone should set a sublabel (transcribe 100%)
        // even if the fraction stays indeterminate from the min perspective.
        var gotSubLabel = false
        let exp = expectation(description: "sublabel after asrDone")
        exp.assertForOverFulfill = false

        let relay = JobProgressRelay(jobID: "sublabeltest") { _, snap in
            if snap.sublabel != nil { gotSubLabel = true; exp.fulfill() }
        }
        relay.set(stage: .transcribeAndDiarize, fraction: nil, sublabel: nil)
        relay.report(.asrDone)

        wait(for: [exp], timeout: 1)
        XCTAssertTrue(gotSubLabel, "Should have published a sublabel after asrDone")
    }

    // MARK: Thread safety smoke

    func testConcurrentReportDoesNotCrash() {
        // 10 threads firing 100 events each — no crash, no hang.
        let relay = JobProgressRelay(jobID: "threadtest") { _, _ in }
        relay.set(stage: .transcribeAndDiarize, fraction: nil, sublabel: nil)

        DispatchQueue.concurrentPerform(iterations: 10) { i in
            for j in 0..<100 {
                let f = Double(j) / 99.0
                if i % 2 == 0 {
                    relay.report(.asr(f))
                } else {
                    relay.report(.diarization(f))
                }
            }
        }

        // If we reach here without a crash or deadlock, the test passes.
        // Give a short drain window so any pending Tasks don't trip other tests.
        let drainExp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drainExp.fulfill() }
        wait(for: [drainExp], timeout: 2)
    }

    // MARK: Compact stage fraction

    func testCompactFractionTracked() {
        var lastSnap: JobProgress?
        let exp = expectation(description: "compact fraction")
        exp.assertForOverFulfill = false

        let relay = JobProgressRelay(jobID: "compacttest") { _, snap in
            if snap.stage == .compact, snap.fraction != nil { lastSnap = snap; exp.fulfill() }
        }
        relay.set(stage: .compact, fraction: 0.75, sublabel: nil)

        wait(for: [exp], timeout: 1)
        XCTAssertEqual(lastSnap?.fraction ?? -1, 0.75, accuracy: 0.01)
    }
}
