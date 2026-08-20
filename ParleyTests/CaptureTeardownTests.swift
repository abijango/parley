import XCTest
@testable import Parley

/// Regression guards for the 2026-08-12 stop-path freeze.
///
/// A Teams call ending reconfigures the audio device *and* triggers auto-stop from
/// the same event. `MicCapture.rebuildEngine()` was mid-flight, parked inside a
/// CoreAudio IPC for 57s, holding `rebuildQueue`; `MicCapture.stop()` then did
/// `rebuildQueue.sync` from the main actor and the whole UI froze behind it.
///
/// The ordering rules below are what actually prevent a recurrence, and none of
/// them can be exercised without real audio hardware — starting an `AVAudioEngine`
/// or a Core Audio process tap in a unit test is neither hermetic nor reliable. So
/// they are pinned against the source, the same way `SpeechAnalyzerSessionClockTests`
/// pins its invariants.
final class CaptureTeardownTests: XCTestCase {

    // MARK: - Behavioural

    /// `stop()` on a capture that never started must return immediately rather than
    /// dispatch teardown — this is the `beginStop()` guard, which is also what makes
    /// quit's double teardown (menu button, then `applicationWillTerminate`) safe.
    func testStopOnNeverStartedCaptureReturnsWithoutHanging() async {
        let mic = MicCapture(ringBuffer: AudioRingBuffer(capacity: 1024), archiveURL: nil)
        await mic.stop()
        mic.stopBlocking(timeout: 1)

        let system = SystemAudioCapture(ringBuffer: AudioRingBuffer(capacity: 1024), archiveURL: nil)
        await system.stop()
        system.stopBlocking(timeout: 1)
    }

    // MARK: - The deadlock itself

    func testMicCaptureNeverBlocksTheCallerOnTheRebuildQueue() throws {
        let src = try Self.source("Parley/Audio/MicCapture.swift")
        // The exact construct that froze the app.
        XCTAssertFalse(src.contains("rebuildQueue.sync"),
                       "MicCapture must never sync onto rebuildQueue — a rebuild can hold it for tens of seconds inside CoreAudio")
        XCTAssertTrue(src.contains("func stop() async"),
                      "stop() must be async so callers await teardown instead of blocking on it")
        XCTAssertTrue(src.contains("func stopBlocking"),
                      "quit needs a bounded synchronous stop; applicationWillTerminate cannot await")
    }

    func testSystemAudioCaptureTearsDownOffTheCallersThread() throws {
        let src = try Self.source("Parley/Audio/SystemAudioCapture.swift")
        XCTAssertTrue(src.contains("func stop() async"),
                      "teardown() is four IPCs into coreaudiod — the same wedged path the mic hit")
        XCTAssertTrue(src.contains("func stopBlocking"))
        XCTAssertTrue(src.contains("teardownQueue"),
                      "teardown must not run on ioQueue: AudioDeviceStop waits for the IO proc to drain")
    }

    // MARK: - Rebuild ordering

    /// The gap must be measured *after* the blocking read, and the early-out for a
    /// concurrent stop must come *after* the archive is padded. Bailing before the
    /// padding drops it on precisely the path that needs it, leaving `mic.caf` short
    /// by however long CoreAudio stalled and desynchronized from `system.caf`.
    func testRebuildMeasuresOutageAfterTheBlockingReadAndPadsBeforeBailing() throws {
        let src = try Self.source("Parley/Audio/MicCapture.swift")

        let blockingRead = try Self.index(of: "let format = freshEngine.inputNode.outputFormat(forBus: 0)", in: src)
        let measure = try Self.index(of: "let outageSeconds = max(0, Date().timeIntervalSince(lastBufferDate))", in: src)
        let pad = try Self.index(of: "archiver.appendSilence(seconds: outageSeconds)", in: src)
        let bail = try Self.index(of: "guard isRunning else {", in: src)

        XCTAssertLessThan(blockingRead, measure,
                          "outage must be re-measured after inputNode returns, not sampled before it blocks")
        XCTAssertLessThan(measure, pad)
        XCTAssertLessThan(pad, bail,
                          "the stop early-out must come after appendSilence, or the padding is dead code")
    }

    // MARK: - Stop path in RecordingController

    func testStopDoesNotCallCaptureStopSynchronously() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        XCTAssertFalse(src.contains("micCapture?.stop()"),
                       "the main actor must not drive capture teardown directly")
        XCTAssertFalse(src.contains("systemCapture?.stop()"))
        XCTAssertTrue(src.contains("micCapture?.stopBlocking()"),
                      "teardownForQuit is the one place a bounded synchronous wait is correct")
    }

    /// The offline pass re-transcribes `mic.caf`, and MicCapture flushes that file's
    /// tail as the last step of teardown. Enqueuing before the flush races the ASR
    /// pass against a still-open archive.
    func testOfflineJobIsEnqueuedOnlyAfterTheArchiveIsFlushed() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        let finalizeBody = try Self.body(ofFunction: "private func finalize(captureTeardown:", in: src)

        let markPending = try Self.index(of: "SessionStore.setOfflineStatus(.pending", in: finalizeBody)
        let await_ = try Self.index(of: "await captureTeardown?.value", in: finalizeBody)
        let enqueue = try Self.index(of: "offlineService.enqueue(OfflineJob(", in: finalizeBody)

        XCTAssertLessThan(markPending, await_,
                          "the manifest must be marked .pending before the wait, or quitting mid-wait strands the session as finalized-but-unqueued")
        XCTAssertLessThan(await_, enqueue,
                          "the offline job must be enqueued after the capture teardown completes")
    }

    /// finalize() snapshots session identity from live properties, so it must still be
    /// invoked synchronously from stop(). Deferring it behind the teardown would let a
    /// recording started in the meantime redirect this session's output.
    func testFinalizeIsStillCalledSynchronouslyFromStop() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        let stopBody = try Self.body(ofFunction: "func stop() {", in: src)

        // Positional AND structural. The regression this guards against is finalize()
        // being moved *inside* one of stop()'s Task blocks, which both a `contains`
        // check and an indentation-matching anchor will happily accept — a mutation
        // test proved exactly that. Brace depth is what actually discriminates.
        let teardownTask = try Self.index(of: "let captureTeardown = Task.detached {", in: stopBody)
        let call = try Self.index(of: "finalize(captureTeardown: captureTeardown)", in: stopBody)

        XCTAssertLessThan(teardownTask, call)
        XCTAssertEqual(Self.braceDepth(before: call, in: stopBody), 0,
                       "finalize() must be called directly in stop()'s body, not nested inside a Task — deferring it lets a newly started recording redirect this session's output")
        XCTAssertFalse(stopBody.contains("await finalize("),
                       "finalize must not move behind the teardown await")
    }

    /// The quit drain blocks the main thread, so the task it waits on must be detached.
    /// A main-actor task would need that same thread to resume between its awaits, and
    /// the pair would deadlock until the timeout expired every single time.
    func testCaptureTeardownIsDetachedSoTheQuitDrainCannotDeadlock() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        XCTAssertTrue(src.contains("let captureTeardown = Task.detached {"),
                      "teardown must be detached — drainOnQuit blocks the main thread waiting on it")
        XCTAssertTrue(src.contains("Self.drainOnQuit(captureTeardown)"),
                      "quitting just after a stop must wait on the in-flight teardown, not find two nils")
    }

    // MARK: - Helpers

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A missing anchor FAILS rather than skips. These are regression guards: if the
    /// guarded code is renamed or deleted, the guard must go loud, not quietly stop
    /// checking anything.
    private struct AnchorNotFound: Error, CustomStringConvertible {
        let needle: String
        var description: String {
            "anchor not found — the guarded code was renamed or removed, so this invariant is no longer checked: \(needle)"
        }
    }

    private static func index(of needle: String, in haystack: String) throws -> Int {
        guard let range = haystack.range(of: needle) else { throw AnchorNotFound(needle: needle) }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    /// Net `{` minus `}` before `offset` — the nesting level of that point relative to
    /// the enclosing function body, where 0 means "directly in the body". Counts braces
    /// in comments and string literals too, which is fine for the functions checked here
    /// (they contain neither) but would need lexing to generalize.
    private static func braceDepth(before offset: Int, in text: String) -> Int {
        let head = text.prefix(offset)
        return head.reduce(0) { depth, ch in
            switch ch {
            case "{": return depth + 1
            case "}": return depth - 1
            default: return depth
            }
        }
    }

    /// Text from a function's declaration to the start of the next top-level `func`,
    /// so ordering assertions can't accidentally match an identical call elsewhere in
    /// the file (`offlineService.enqueue` appears three times).
    private static func body(ofFunction declaration: String, in src: String) throws -> String {
        guard let start = src.range(of: declaration) else { throw AnchorNotFound(needle: declaration) }
        let rest = src[start.upperBound...]
        guard let next = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ") else {
            return String(rest)
        }
        return String(rest[..<next.lowerBound])
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
