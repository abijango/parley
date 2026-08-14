import XCTest
@testable import Parley

/// Exercises the real detection mechanism — an actually-blocked main queue — rather
/// than a stubbed clock. XCTest runs test methods on the main thread, so a `Thread.sleep`
/// here wedges the main queue exactly the way the 2026-08-04 freeze did, and the watchdog
/// has to notice from its own background queue.
///
/// These tests poll rather than sleep for a fixed span: `sample` spends a second or two
/// symbolizing after its sampling window closes, and it runs synchronously on the
/// watchdog's own queue (so no tick — including the one that reports recovery — can land
/// until it returns).
final class MainActorWatchdogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Sub-second budget so the tests stay fast; the production instance uses a 5s
    /// threshold so no legitimate hitch trips it.
    private func makeWatchdog(cooldown: TimeInterval = 120) -> MainActorWatchdog {
        var config = MainActorWatchdog.Config()
        config.stallThreshold = 0.4
        config.tickInterval = 0.1
        config.sampleSeconds = 1
        config.captureCooldown = cooldown
        config.directory = tempDir
        config.mirrorToAppLog = false
        return MainActorWatchdog(config: config)
    }

    // MARK: Helpers

    private func freezeLog() -> String {
        (try? String(contentsOf: tempDir.appendingPathComponent("freeze.log"), encoding: .utf8)) ?? ""
    }

    private func sampleFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        return names.filter { $0.hasPrefix("freeze-") && $0.hasSuffix(".txt") }
    }

    /// Lets the main queue drain (and watchdog ticks land) *without* blocking it.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            settle(0.05)
        }
        XCTFail("timed out waiting for \(what) — log was: \(freezeLog())")
    }

    // MARK: Tests

    func testDetectsBlockedMainQueueAndCapturesStacks() throws {
        let watchdog = makeWatchdog()
        watchdog.start()
        defer { watchdog.stop() }

        settle(0.3)                          // let the first ping/pong round-trip
        XCTAssertTrue(freezeLog().isEmpty, "a responsive main queue must not report a stall")

        Thread.sleep(forTimeInterval: 1.0)   // wedge the main queue

        waitUntil("a stall report") { self.freezeLog().contains("main actor stalled") }
        waitUntil("a stack capture") { self.sampleFiles().count == 1 }
        waitUntil("a recovery report") { self.freezeLog().contains("main actor recovered") }

        // The capture must contain real stacks, not be an empty shell.
        let name = try XCTUnwrap(sampleFiles().first)
        let capture = try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(capture.contains("Analysis of sampling"), "sample output looks truncated")
    }

    func testResponsiveMainQueueIsNeverReported() {
        let watchdog = makeWatchdog()
        watchdog.start()
        defer { watchdog.stop() }

        settle(1.5)   // main queue stays free the whole time

        XCTAssertEqual(freezeLog(), "", "no stall should be reported for a healthy main queue")
        XCTAssertTrue(sampleFiles().isEmpty, "no stacks should be captured for a healthy main queue")
    }

    /// A long freeze must not spawn a `sample` per tick.
    func testCaptureIsRateLimited() {
        let watchdog = makeWatchdog(cooldown: 60)   // production-like: one capture per freeze
        watchdog.start()
        defer { watchdog.stop() }

        settle(0.2)
        Thread.sleep(forTimeInterval: 3.0)          // a long block spanning ~30 ticks
        waitUntil("the first stack capture") { self.sampleFiles().count >= 1 }
        waitUntil("a recovery report") { self.freezeLog().contains("main actor recovered") }
        settle(0.5)                                 // give any extra capture a chance to appear

        XCTAssertEqual(sampleFiles().count, 1, "cooldown should hold the freeze to one capture")
    }

    /// Regression: a 98-minute freeze on 2026-08-07 wrote ~50 captures at ~22 MB each —
    /// 1.3 GB in the log directory. The cooldown alone does not bound a long freeze.
    func testCaptureIsCappedPerFreeze() {
        let now = Date()
        typealias D = MainActorWatchdog.CaptureDecision
        func decide(_ taken: Int, lastCaptureAt: Date? = nil) -> D {
            MainActorWatchdog.captureDecision(capturesThisFreeze: taken, maxPerFreeze: 3,
                                              lastCaptureAt: lastCaptureAt, now: now,
                                              cooldown: 120)
        }

        XCTAssertEqual(decide(0), .capture)
        XCTAssertEqual(decide(2), .capture, "under the cap, still worth a sample")
        XCTAssertEqual(decide(3), .capped, "at the cap, announce once")
        XCTAssertEqual(decide(4), .skip, "past the cap, stay silent")
        XCTAssertEqual(decide(9), .skip)

        // The cooldown still gates captures below the cap.
        XCTAssertEqual(decide(1, lastCaptureAt: now.addingTimeInterval(-10)), .skip,
                       "10s after the last capture is inside the 120s cooldown")
        XCTAssertEqual(decide(1, lastCaptureAt: now.addingTimeInterval(-200)), .capture,
                       "200s after the last capture clears the cooldown")

        // The cap outranks an elapsed cooldown — otherwise a long freeze never stops.
        XCTAssertEqual(decide(3, lastCaptureAt: now.addingTimeInterval(-9999)), .capped)
    }

    /// Retention is bounded across freezes too: each capture is ~22 MB.
    func testOldCapturesArePruned() throws {
        var config = MainActorWatchdog.Config()
        config.retainedCaptures = 3
        config.directory = tempDir
        config.mirrorToAppLog = false
        let watchdog = MainActorWatchdog(config: config)

        // Filenames carry a zero-padded timestamp, so lexicographic order is age order.
        let names = (1...10).map { String(format: "freeze-2026-08-10-1200%02d.txt", $0) }
        for name in names {
            try "stack".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // An unrelated file must survive pruning.
        try "log".write(to: tempDir.appendingPathComponent("freeze.log"), atomically: true, encoding: .utf8)

        watchdog.pruneCaptures()

        XCTAssertEqual(sampleFiles().sorted(), Array(names.suffix(3)),
                       "only the newest 3 captures should remain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("freeze.log").path),
                      "pruning must not touch freeze.log")
    }

    func testPruneIsANoopBelowTheRetentionLimit() throws {
        var config = MainActorWatchdog.Config()
        config.retainedCaptures = 8
        config.directory = tempDir
        config.mirrorToAppLog = false
        let watchdog = MainActorWatchdog(config: config)

        let names = ["freeze-2026-08-10-120001.txt", "freeze-2026-08-10-120002.txt"]
        for name in names {
            try "stack".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        watchdog.pruneCaptures()

        XCTAssertEqual(sampleFiles().sorted(), names, "nothing to prune below the limit")
        XCTAssertFalse(freezeLog().contains("pruned"), "a no-op prune should not be logged")
    }
}
