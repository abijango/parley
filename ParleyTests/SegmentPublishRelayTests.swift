import XCTest
@testable import Parley

@MainActor
final class SegmentPublishRelayTests: XCTestCase {

    func testBurstOfSubmitsIsThrottled() {
        let windowSec = 0.6
        let maxExpected = Int(ceil(windowSec / 0.2)) + 2

        var publishCount = 0
        let relay = SegmentPublishRelay { _ in publishCount += 1 }

        let seg = Segment(track: .me, start: 0, end: 1, text: "hi", confirmed: false)
        let deadline = Date(timeIntervalSinceNow: windowSec)
        while Date() < deadline {
            relay.submit([seg])
            Thread.sleep(forTimeInterval: 0.001)
        }

        let drain = expectation(description: "deferred drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { drain.fulfill() }
        wait(for: [drain], timeout: 2)

        XCTAssertLessThanOrEqual(publishCount, maxExpected,
            "Expected ≤\(maxExpected) publishes, got \(publishCount)")
    }

    func testImmediateSubmitPublishesNow() {
        var published = false
        let relay = SegmentPublishRelay { _ in published = true }
        let seg = Segment(track: .remote, start: 0, end: 1, text: "ok", confirmed: true)

        relay.submit([seg], immediate: true)

        XCTAssertTrue(published)
    }
}