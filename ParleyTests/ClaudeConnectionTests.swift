import XCTest
@testable import Parley

/// Coverage for ClaudeConnection's pure helpers: binary resolution precedence and the
/// `~/.claude.json` login heuristic. The subprocess/probe orchestration isn't unit-tested
/// (it spawns the real CLI); these cover the decision logic it feeds on.
final class ClaudeConnectionTests: XCTestCase {

    // MARK: resolveBinary

    func testConfiguredPathWinsWhenExecutable() {
        let resolved = ClaudeConnection.resolveBinary(
            configured: "/custom/claude",
            candidates: ["/opt/homebrew/bin/claude"],
            isExecutable: { _ in true })
        XCTAssertEqual(resolved, "/custom/claude")
    }

    func testFallsBackToFirstExecutableCandidate() {
        let resolved = ClaudeConnection.resolveBinary(
            configured: "/missing/claude",
            candidates: ["/also/missing", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" })
        XCTAssertEqual(resolved, "/opt/homebrew/bin/claude")
    }

    func testNilWhenNothingExecutable() {
        let resolved = ClaudeConnection.resolveBinary(
            configured: "/missing/claude",
            candidates: ["/a", "/b"],
            isExecutable: { _ in false })
        XCTAssertNil(resolved)
    }

    func testEmptyConfiguredPathIsSkipped() {
        let resolved = ClaudeConnection.resolveBinary(
            configured: "",
            candidates: ["/opt/homebrew/bin/claude"],
            isExecutable: { _ in true })
        XCTAssertEqual(resolved, "/opt/homebrew/bin/claude")
    }

    // MARK: parseClaudeJSON

    func testParseLoggedInWithEmail() {
        let json = #"{"oauthAccount":{"accountUuid":"u","emailAddress":"a@b.com","organizationName":"Acme"}}"#
        let r = ClaudeConnection.parseClaudeJSON(Data(json.utf8))
        XCTAssertTrue(r.loggedIn)
        XCTAssertEqual(r.account, "a@b.com")
    }

    func testParseLoggedInOrgFallback() {
        let json = #"{"oauthAccount":{"organizationName":"Acme"}}"#
        let r = ClaudeConnection.parseClaudeJSON(Data(json.utf8))
        XCTAssertTrue(r.loggedIn)
        XCTAssertEqual(r.account, "Acme")
    }

    func testParseNotLoggedInWhenNoOauthAccount() {
        let json = #"{"numStartups":5,"theme":"dark"}"#
        let r = ClaudeConnection.parseClaudeJSON(Data(json.utf8))
        XCTAssertFalse(r.loggedIn)
        XCTAssertNil(r.account)
    }

    func testParseMalformedJSONIsNotLoggedIn() {
        let r = ClaudeConnection.parseClaudeJSON(Data("not json".utf8))
        XCTAssertFalse(r.loggedIn)
    }
}
