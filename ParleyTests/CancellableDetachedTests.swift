import XCTest
@testable import Parley

final class CancellableDetachedTests: XCTestCase {

    func testCancelReachesDetachedWorker() async {
        let worker = Task {
            await CancellableDetached.run {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return Task.isCancelled
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        worker.cancel()
        let cancelled = await worker.value
        XCTAssertTrue(cancelled, "Cancel on the outer Task must reach the detached worker")
    }

    func testParkRestoresPendingWithoutBurningAttempts() {
        let parked = OfflineJobPark.diskState(attemptsBeforeRun: 1)
        XCTAssertEqual(parked.status, .pending)
        XCTAssertEqual(parked.attempts, 1)
    }

    func testCancelDoesNotStampDone() {
        XCTAssertEqual(OfflineQueueCancel.diskStatus, .cancelled)
        XCTAssertNotEqual(OfflineQueueCancel.diskStatus, .done)
    }

    func testCancelledOfflineIsNotRerunAtLaunch() {
        XCTAssertFalse(SessionStore.isRerunnableOffline(.cancelled))
        XCTAssertFalse(SessionStore.isRerunnableOffline(.done))
        XCTAssertFalse(SessionStore.isRerunnableOffline(.failed))
        XCTAssertFalse(SessionStore.isRerunnableOffline(nil))
        XCTAssertTrue(SessionStore.isRerunnableOffline(.pending))
        XCTAssertTrue(SessionStore.isRerunnableOffline(.running))
    }
}
