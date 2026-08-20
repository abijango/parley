import XCTest
@testable import Parley

final class MeetingSourceTests: XCTestCase {

    func testPrefixMatcherClaimsNewTeamsBundle() {
        let matcher = BundleMatcher.prefix("com.microsoft.teams")
        XCTAssertTrue(matcher.matches("com.microsoft.teams"))
        XCTAssertTrue(matcher.matches("com.microsoft.teams2"),
                      "new Teams is teams2, not teams.<suffix>")
        XCTAssertTrue(matcher.matches("COM.MICROSOFT.TEAMS2"))
        XCTAssertFalse(matcher.matches("us.zoom.xos"))
    }

    func testRegistryAttachesTeamsSourceToTeams2() {
        let call = CallIdentity(bundleID: "com.microsoft.teams2", pid: 1, startedAt: Date())
        XCTAssertNotNil(MeetingSourceRegistry.source(for: call),
                        "source=false on the poller means title and roster never run")
        XCTAssertEqual(MeetingSourceRegistry.displayName(for: "com.microsoft.teams2"),
                       "Microsoft Teams")
    }

    func testExactMatcherDoesNotPrefix() {
        let matcher = BundleMatcher.exact("us.zoom.xos")
        XCTAssertTrue(matcher.matches("us.zoom.xos"))
        XCTAssertFalse(matcher.matches("us.zoom.xos.helper"))
    }
}
