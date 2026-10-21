import XCTest
@testable import Parley

@MainActor
final class AppIdentityTests: XCTestCase {
    private let known: Set<String> = ["cisco-systems.spark", "com.google.chrome"]

    func testWebexHelperHandoffKeepsTheCallAlive() {
        var state = CallDetectionState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func poll(_ dt: TimeInterval, _ caps: [CapturingProcess]) -> CallDetectionEvent? {
            CallDetection.step(&state, capturers: caps, now: start.addingTimeInterval(dt),
                               known: known, grace: 10, startDebounce: 1.5)
        }
        let spark = CapturingProcess(pid: 1, bundleID: "cisco-systems.spark")
        let helper = CapturingProcess(pid: 2, bundleID: "cisco-systems.sparkhelper")

        XCTAssertNotNil(poll(0, [spark, helper]))
        XCTAssertEqual(poll(1.5, [spark, helper]), .started(webex(pid: 1)))
        XCTAssertNil(poll(20, [helper]), "helper still holds the mic, so the call stays up")
        XCTAssertEqual(state.active?.bundleID, "cisco-systems.spark")
        XCTAssertNil(poll(40, [helper]))
        XCTAssertEqual(poll(50, []), .ended(webex(pid: 1), after: 10))
        XCTAssertNil(state.active)
    }

    func testWebexHelperAloneStartsAsWebex() {
        var state = CallDetectionState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let helper = CapturingProcess(pid: 2, bundleID: "Cisco-Systems.SparkHelper")
        _ = CallDetection.step(&state, capturers: [helper], now: start,
                               known: known, grace: 10, startDebounce: 1.5)
        let started = CallDetection.step(&state, capturers: [helper], now: start.addingTimeInterval(1.5),
                                         known: known, grace: 10, startDebounce: 1.5)
        XCTAssertEqual(started, .started(webex(pid: 2)))
    }

    func testWebexHelperThenParentConfirmsOnce() {
        var state = CallDetectionState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func poll(_ dt: TimeInterval, _ caps: [CapturingProcess]) -> CallDetectionEvent? {
            CallDetection.step(&state, capturers: caps, now: start.addingTimeInterval(dt),
                               known: known, grace: 10, startDebounce: 1.5)
        }
        XCTAssertNotNil(poll(0, [CapturingProcess(pid: 2, bundleID: "cisco-systems.sparkhelper")]))
        XCTAssertNil(poll(0.4, [CapturingProcess(pid: 1, bundleID: "cisco-systems.spark")]))
        guard case .started(let call) = poll(1.5, [CapturingProcess(pid: 1, bundleID: "cisco-systems.spark")]) else {
            return XCTFail("the handoff during confirmation is still one Webex call")
        }
        XCTAssertEqual(call.bundleID, "cisco-systems.spark")
        XCTAssertTrue(call.known)
        XCTAssertEqual(call.displayName, "Webex")
    }

    func testLookalikeBundleDoesNotBecomeWebex() {
        var state = CallDetectionState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lookalike = CapturingProcess(pid: 9, bundleID: "cisco-systems.sparkfoo")
        _ = CallDetection.step(&state, capturers: [lookalike], now: start,
                               known: known, grace: 10, startDebounce: 1.5)
        let started = CallDetection.step(&state, capturers: [lookalike], now: start.addingTimeInterval(1.5),
                                         known: known, grace: 10, startDebounce: 1.5)
        guard case .started(let call) = started else { return XCTFail("expected a call") }
        XCTAssertEqual(call.bundleID, "cisco-systems.sparkfoo")
        XCTAssertFalse(call.known)
    }

    func testChromeHelperStaysChromeAcrossPidSwap() {
        var state = CallDetectionState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func poll(_ dt: TimeInterval, pid: pid_t) -> CallDetectionEvent? {
            CallDetection.step(&state,
                               capturers: [CapturingProcess(pid: pid, bundleID: "com.google.Chrome.helper")],
                               now: start.addingTimeInterval(dt),
                               known: known, grace: 10, startDebounce: 1.5)
        }
        XCTAssertNotNil(poll(0, pid: 10))
        XCTAssertNil(poll(0.4, pid: 11))
        guard case .started(let call) = poll(1.5, pid: 11) else { return XCTFail("expected Chrome to start") }
        XCTAssertEqual(call.bundleID, "com.google.chrome")
        XCTAssertEqual(call.displayName, "Chrome")
        XCTAssertTrue(call.known)
        XCTAssertNil(poll(30, pid: 12))
        XCTAssertEqual(state.active?.bundleID, "com.google.chrome")
    }

    func testWebKitGPUDoesNotBecomeSafari() {
        var state = CallDetectionState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let gpu = CapturingProcess(pid: 4, bundleID: "com.apple.WebKit.GPU")
        let safariKnown: Set<String> = ["com.apple.safari"]
        _ = CallDetection.step(&state, capturers: [gpu], now: start,
                               known: safariKnown, grace: 10, startDebounce: 1.5)
        let started = CallDetection.step(&state, capturers: [gpu], now: start.addingTimeInterval(1.5),
                                         known: safariKnown, grace: 10, startDebounce: 1.5)
        guard case .started(let call) = started else { return XCTFail("expected a call") }
        XCTAssertEqual(call.bundleID, "com.apple.webkit.gpu")
        XCTAssertFalse(call.known)
    }

    func testWebexHelperDisplayName() {
        XCTAssertEqual(MeetingSourceRegistry.displayName(for: "cisco-systems.sparkhelper"), "Webex")
    }

    private func webex(pid: pid_t) -> DetectedCall {
        DetectedCall(pid: pid, bundleID: "cisco-systems.spark", displayName: "Webex", known: true)
    }
}
