import XCTest
@testable import Parley

final class GrokConnectionTests: XCTestCase {

    func testResolveBinaryPrefersConfiguredWhenExecutable() {
        let resolved = GrokConnection.resolveBinary(
            configured: "/cfg/grok",
            candidates: ["/a/grok", "/b/grok"],
            isExecutable: { $0 == "/cfg/grok" })
        XCTAssertEqual(resolved, "/cfg/grok")
    }

    func testResolveBinaryFallsBackToCandidates() {
        let resolved = GrokConnection.resolveBinary(
            configured: "/missing/grok",
            candidates: ["/a/grok", "/b/grok"],
            isExecutable: { $0 == "/b/grok" })
        XCTAssertEqual(resolved, "/b/grok")
    }

    func testResolveBinaryNilWhenNothingExecutable() {
        let resolved = GrokConnection.resolveBinary(
            configured: "",
            candidates: ["/a", "/b"],
            isExecutable: { _ in false })
        XCTAssertNil(resolved)
    }

    func testParseAuthJSONExtractsEmail() throws {
        let json = """
        {
          "https://auth.x.ai::uuid": {
            "key": "secret",
            "email": "user@example.com",
            "refresh_token": "rt"
          }
        }
        """
        let r = GrokConnection.parseAuthJSON(Data(json.utf8))
        XCTAssertTrue(r.loggedIn)
        XCTAssertEqual(r.account, "user@example.com")
    }

    func testParseAuthJSONEmpty() {
        let r = GrokConnection.parseAuthJSON(Data("{}".utf8))
        XCTAssertFalse(r.loggedIn)
        XCTAssertNil(r.account)
    }

    func testParseAuthJSONGarbage() {
        let r = GrokConnection.parseAuthJSON(Data("not json".utf8))
        XCTAssertFalse(r.loggedIn)
    }
}
