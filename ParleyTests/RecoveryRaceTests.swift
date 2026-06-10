import XCTest
@testable import Parley

/// Regression coverage for the finalize() data-loss race (Fix A) and the
/// orphan-recovery backstop (Fix C).
///
/// All tests operate on PURE PREDICATES in `SessionStore` — no filesystem
/// dependency, no hardcoded-directory scans.
final class RecoveryRaceTests: XCTestCase {

    // MARK: Helpers

    /// A minimal manifest builder. Only the fields the predicates inspect are set;
    /// the rest use stable sentinel values.
    private func manifest(
        status: SessionManifest.Status,
        offlineStatus: SessionManifest.OfflineStatus? = nil,
        summaryStatus: SessionManifest.SummaryStatus? = nil
    ) -> SessionManifest {
        var m = SessionManifest(
            id: "2026-06-10-000000",
            title: "Test session",
            attendees: "",
            filing: "",
            model: "whisper-large-v3",
            computeMode: "local",
            startedAt: Date(timeIntervalSince1970: 0),
            lastHeartbeat: Date(timeIntervalSince1970: 1),
            status: status,
            startedByDetection: false,
            callBundleID: nil,
            callDisplayName: nil,
            manualNotes: "",
            audioTracks: ["mic.caf"],
            titleSource: nil,
            suggestedAttendees: nil
        )
        m.offlineStatus = offlineStatus
        m.summaryStatus = summaryStatus
        return m
    }

    // MARK: isCrashed(_:)

    func testActiveManifestedIsCrashed() {
        // An `.active` manifest means the app died mid-recording.
        let m = manifest(status: .active)
        XCTAssertTrue(SessionStore.isCrashed(m))
    }

    func testFinalizedManifestIsNotCrashed() {
        let m = manifest(status: .finalized)
        XCTAssertFalse(SessionStore.isCrashed(m))
    }

    func testFinalizedWithPendingOfflineIsNotCrashed() {
        let m = manifest(status: .finalized, offlineStatus: .pending)
        XCTAssertFalse(SessionStore.isCrashed(m))
    }

    // MARK: isFinalizedButUnlanded(_:) — Fix A / Fix C predicate

    /// T1: A session interrupted between the two halves (status `.finalized`,
    /// offlineStatus nil, summaryStatus nil) MUST match the orphan predicate.
    func testFinalizedWithNilStatusesIsOrphaned() {
        let m = manifest(status: .finalized, offlineStatus: nil, summaryStatus: nil)
        XCTAssertTrue(SessionStore.isFinalizedButUnlanded(m),
                      "A session whose manifest was stamped .finalized before the transcript write is orphaned")
    }

    /// T2a: A clean-stop session (speaker engine → offlineStatus .pending) must NOT be orphaned.
    func testFinalizedWithPendingOfflineIsNotOrphaned() {
        let m = manifest(status: .finalized, offlineStatus: .pending)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m),
                       "A session that made it to the offline queue is not orphaned")
    }

    /// T2b: A fully-processed session (offlineStatus .done) must NOT be orphaned.
    func testFinalizedWithDoneOfflineIsNotOrphaned() {
        let m = manifest(status: .finalized, offlineStatus: .done)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m))
    }

    /// T2c: A session with a summary queued (non-speaker engine path) must NOT be orphaned.
    func testFinalizedWithQueuedSummaryIsNotOrphaned() {
        let m = manifest(status: .finalized, offlineStatus: nil, summaryStatus: .queued)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m),
                       "A session whose summary was queued successfully is not orphaned")
    }

    /// T2d: A session with a done summary must NOT be orphaned.
    func testFinalizedWithDoneSummaryIsNotOrphaned() {
        let m = manifest(status: .finalized, summaryStatus: .done)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m))
    }

    /// T3: An `.active` session must match `isCrashed` and must NOT match
    ///     `isFinalizedButUnlanded` (no double-handling between recovery paths).
    func testActiveSessionIsNotOrphanedFinalized() {
        let m = manifest(status: .active)
        XCTAssertTrue(SessionStore.isCrashed(m), "active session belongs to the Recovery sheet")
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m),
                       "active session must not be double-handled as an orphaned-finalized session")
    }

    /// T4: The two predicates are mutually exclusive for all combinations of
    ///     status × (nil/pending/done/failed) × (nil/queued/done/failed).
    func testPredicatesAreMutuallyExclusive() {
        let statuses: [SessionManifest.Status] = [.active, .finalized]
        let offlineStatuses: [SessionManifest.OfflineStatus?] = [nil, .pending, .running, .done, .failed]
        let summaryStatuses: [SessionManifest.SummaryStatus?] = [nil, .queued, .running, .paused, .done, .failed]

        for status in statuses {
            for offline in offlineStatuses {
                for summary in summaryStatuses {
                    let m = manifest(status: status, offlineStatus: offline, summaryStatus: summary)
                    let crashed = SessionStore.isCrashed(m)
                    let orphaned = SessionStore.isFinalizedButUnlanded(m)
                    XCTAssertFalse(crashed && orphaned,
                        "isCrashed and isFinalizedButUnlanded must never both be true — status:\(status) offline:\(String(describing: offline)) summary:\(String(describing: summary))")
                }
            }
        }
    }

    // MARK: Boundary: offline .running (crashed mid-pass)

    func testFinalizedWithRunningOfflineIsNotOrphaned() {
        // `.running` = the offline pass started but the app crashed mid-way.
        // The offline queue's own recovery (pendingOfflineSessions) handles this.
        let m = manifest(status: .finalized, offlineStatus: .running)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m))
    }

    func testFinalizedWithFailedOfflineIsNotOrphaned() {
        let m = manifest(status: .finalized, offlineStatus: .failed)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m))
    }

    // MARK: Boundary: summary .paused / .running

    func testFinalizedWithPausedSummaryIsNotOrphaned() {
        // `.paused` = usage limit trip; still recoverable via the summary queue.
        let m = manifest(status: .finalized, summaryStatus: .paused)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m))
    }

    func testFinalizedWithRunningSummaryIsNotOrphaned() {
        let m = manifest(status: .finalized, summaryStatus: .running)
        XCTAssertFalse(SessionStore.isFinalizedButUnlanded(m))
    }
}
