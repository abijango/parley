import XCTest
@testable import Parley

final class WebexSourceTests: XCTestCase {
    func testRegistryReadsWebex() {
        let call = CallIdentity(bundleID: "cisco-systems.spark", pid: 1, startedAt: Date())
        XCTAssertNotNil(MeetingSourceRegistry.source(for: call))
    }

    func testHelperWindowSuppliesTheTitleWhenTheMainAppIsGeneric() {
        let tree = ScriptedTree(titles: [
            10: ["Webex", "Window"],
            11: ["AEGIS Weekly Update"],
        ])
        let call = CallIdentity(bundleID: "cisco-systems.spark", pid: 10, startedAt: Date())
        let reading = WebexSource(call: call).read(ScanContext(
            call: call,
            tick: 1,
            elapsedSinceCallStart: 2,
            now: Date(),
            runningApps: RunningApps(pids: [
                "cisco-systems.spark": 10,
                "cisco-systems.sparkhelper": 11,
            ]),
            needs: ScanNeeds(title: true, roster: true),
            tree: tree))
        XCTAssertEqual(reading.title?.title, "AEGIS Weekly Update")
        XCTAssertEqual(reading.title?.authority, .callWindow)
        XCTAssertEqual(reading.roster.coverage, .unreadable)
    }

    func testMainWindowWinsOverTheHelper() {
        let tree = ScriptedTree(titles: [
            10: ["Design review"],
            11: ["Someone's chat"],
        ])
        let call = CallIdentity(bundleID: "cisco-systems.spark", pid: 10, startedAt: Date())
        let reading = WebexSource(call: call).read(ScanContext(
            call: call,
            tick: 1,
            elapsedSinceCallStart: 2,
            now: Date(),
            runningApps: RunningApps(pids: [
                "cisco-systems.spark": 10,
                "cisco-systems.sparkhelper": 11,
            ]),
            needs: ScanNeeds(title: true, roster: false),
            tree: tree))
        XCTAssertEqual(reading.title?.title, "Design review")
    }
}

private struct ScriptedTree: MeetingUITree {
    var titles: [pid_t: [String]] = [:]
    func windowTitles(pid: pid_t) -> [String] { titles[pid] ?? [] }
    func nodes(pid: pid_t, inWindowsTitled matches: @escaping @Sendable (String) -> Bool) -> [AXNode] { [] }
    func nodes(pid: pid_t) -> [AXNode] { [] }
    func prepareRichTree(pid: pid_t) {}
}
