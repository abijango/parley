import XCTest
@testable import Parley

@MainActor
final class FluidAsrRoutingTests: XCTestCase {
    func testEnglishLanguageDetection() {
        XCTAssertTrue(FluidAsrRouting.isEnglishStreamingLanguage("en-US"))
        XCTAssertTrue(FluidAsrRouting.isEnglishStreamingLanguage("en-GB"))
        XCTAssertTrue(FluidAsrRouting.isEnglishStreamingLanguage("en"))
        XCTAssertFalse(FluidAsrRouting.isEnglishStreamingLanguage("auto"))
        XCTAssertFalse(FluidAsrRouting.isEnglishStreamingLanguage("de"))
        XCTAssertFalse(FluidAsrRouting.isEnglishStreamingLanguage("es"))
    }

    func testUnifiedRouteRequiresEnglishAndToggle() {
        let settings = AppSettings.shared
        settings.useParakeetUnified = true
        settings.liveStreamingLanguage = "en-US"
        XCTAssertTrue(FluidAsrRouting.usesParakeetUnified(settings: settings))

        settings.liveStreamingLanguage = "de"
        XCTAssertFalse(FluidAsrRouting.usesParakeetUnified(settings: settings))

        settings.liveStreamingLanguage = "en-US"
        settings.useParakeetUnified = false
        XCTAssertFalse(FluidAsrRouting.usesParakeetUnified(settings: settings))
    }

    func testVocabularyBuilderSkipsShortTokens() {
        let terms = FluidVocabularyBuilder.build(
            attendees: "Al, Bob Smith",
            meetingTitle: "Q4 OKR",
            enabled: true)
        let texts = Set(terms.map(\.text))
        XCTAssertFalse(texts.contains("Al"))
        XCTAssertTrue(texts.contains("Bob Smith"))
        XCTAssertTrue(texts.contains("Bob"))
        XCTAssertTrue(texts.contains("Smith"))
    }

    func testVocabularyBuilderDisabledReturnsEmpty() {
        XCTAssertTrue(
            FluidVocabularyBuilder.build(attendees: "Alice", meetingTitle: "Standup", enabled: false).isEmpty)
    }

    func testDisplayModelName() {
        let settings = AppSettings.shared
        settings.useParakeetUnified = true
        settings.liveStreamingLanguage = "en-US"
        XCTAssertEqual(FluidAsrRouting.displayModelName(settings: settings), "Parakeet Unified")

        settings.liveStreamingLanguage = "fr"
        XCTAssertEqual(FluidAsrRouting.displayModelName(settings: settings), "Parakeet")
    }

    func testProfileFromToggleAndLanguage() {
        XCTAssertEqual(
            FluidAsrBinding.profile(useUnified: true, language: "en-US", version: .v3),
            .parakeetUnified)
        XCTAssertEqual(
            FluidAsrBinding.profile(useUnified: true, language: "de", version: .v3),
            .parakeetV3)
        XCTAssertEqual(
            FluidAsrBinding.profile(useUnified: false, language: "en-US", version: .v2),
            .parakeetV2)
        XCTAssertEqual(
            FluidAsrBinding.profile(useUnified: false, language: "en-US", version: .v3),
            .parakeetV3)
    }
}
