import XCTest
@testable import Parley

/// Covers the one piece of real logic in the pure-SwiftUI `TokenField`: how a committed
/// name is classified (dedupe / add-known / route-new). The rest of the field is plain
/// SwiftUI views over a single `[String]` binding, so there's no sync logic to test.
final class TokenFieldTests: XCTestCase {

    private let contacts = ["Naufal Mir", "Andre Nedelcoux", "Vitalii Yuryev"]

    func testExistingTokenIsDuplicate() {
        XCTAssertEqual(
            TokenField.classify("Andre Nedelcoux", tokens: ["Andre Nedelcoux"], completions: contacts),
            .duplicate)
    }

    func testExistingTokenDedupeIsCaseInsensitive() {
        XCTAssertEqual(
            TokenField.classify("andre nedelcoux", tokens: ["Andre Nedelcoux"], completions: contacts),
            .duplicate)
    }

    func testKnownContactIsAdded() {
        XCTAssertEqual(
            TokenField.classify("Vitalii Yuryev", tokens: ["Naufal Mir"], completions: contacts),
            .add)
    }

    func testKnownContactMatchIsCaseInsensitive() {
        XCTAssertEqual(
            TokenField.classify("vitalii yuryev", tokens: [], completions: contacts),
            .add)
    }

    func testGenuinelyNewNameRoutesToCreate() {
        XCTAssertEqual(
            TokenField.classify("Nathan Bender", tokens: ["Naufal Mir"], completions: contacts),
            .createNew)
    }

    func testExistingOutranksCreateNew() {
        // A free-text name already added (not a known contact) is a duplicate, not a re-create.
        XCTAssertEqual(
            TokenField.classify("Nathan Bender", tokens: ["Nathan Bender"], completions: contacts),
            .duplicate)
    }
}
