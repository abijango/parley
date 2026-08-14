import XCTest
@testable import Parley

final class FluidPrepareKeyTests: XCTestCase {
    func testKeysMatchOnlyWhenProfileLanguageAndTierMatch() {
        let a = FluidPrepareKey(profile: .parakeetUnified, language: "en-US", chunkMs: 2240)
        let b = FluidPrepareKey(profile: .parakeetUnified, language: "en-US", chunkMs: 2240)
        let otherProfile = FluidPrepareKey(profile: .parakeetV3, language: "en-US", chunkMs: 2240)
        let otherLang = FluidPrepareKey(profile: .parakeetUnified, language: "de", chunkMs: 2240)
        let otherTier = FluidPrepareKey(profile: .parakeetUnified, language: "en-US", chunkMs: 1120)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, otherProfile)
        XCTAssertNotEqual(a, otherLang)
        XCTAssertNotEqual(a, otherTier)
    }
}
