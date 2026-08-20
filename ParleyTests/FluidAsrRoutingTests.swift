import XCTest
import FluidAudio
@testable import Parley

private enum FluidAsrRoutingTestSupport {
    nonisolated static func token(_ piece: String, start: Double, end: Double) -> TokenTiming {
        TokenTiming(token: piece, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }
}

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

    func testVocabularyPolicyShouldLoad() {
        let terms = [CustomVocabularyTerm(text: "Alice", weight: 10)]
        XCTAssertFalse(FluidVocabularyPolicy.shouldLoad(enabled: false, terms: terms))
        XCTAssertFalse(FluidVocabularyPolicy.shouldLoad(enabled: true, terms: []))
        XCTAssertTrue(FluidVocabularyPolicy.shouldLoad(enabled: true, terms: terms))
    }

    func testOfflineTimingsNativeWhenTranscriptMatchesTokens() {
        let timings = [
            FluidAsrRoutingTestSupport.token(" hello", start: 0.1, end: 0.5),
            FluidAsrRoutingTestSupport.token(" world", start: 0.5, end: 1.0),
        ]
        let resolved = FluidOfflineTimings.resolve(
            transcript: "hello world", timings: timings, clipDuration: 10)
        guard case .native(let words) = resolved else {
            return XCTFail("expected native timings")
        }
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].text, " hello")
        XCTAssertEqual(words[1].start, 0.5)
    }

    func testOfflineTimingsZipWhenRescoreKeepsWordCount() {
        let timings = [
            FluidAsrRoutingTestSupport.token("\u{2581}Now", start: 1.0, end: 1.4),
            FluidAsrRoutingTestSupport.token("fall", start: 1.4, end: 1.8),
            FluidAsrRoutingTestSupport.token("\u{2581}Meer", start: 1.8, end: 2.4),
        ]
        let resolved = FluidOfflineTimings.resolve(
            transcript: "Naufal Mir", timings: timings, clipDuration: 10)
        guard case .native(let words) = resolved else {
            return XCTFail("expected zip-aligned native timings")
        }
        XCTAssertEqual(words.map(\.text), ["\u{2581}Naufal", "\u{2581}Mir"])
        XCTAssertEqual(words[0].start, 1.0)
        XCTAssertEqual(words[0].end, 1.8)
        XCTAssertEqual(words[1].start, 1.8)
        XCTAssertEqual(words[1].end, 2.4)
    }

    func testOfflineTimingsSpreadOnEnvelopeWhenWordCountDiffers() {
        let timings = [
            FluidAsrRoutingTestSupport.token(" hi", start: 1.0, end: 1.4),
            FluidAsrRoutingTestSupport.token(" there", start: 1.4, end: 2.0),
        ]
        let resolved = FluidOfflineTimings.resolve(
            transcript: "hello there everyone", timings: timings, clipDuration: 10)
        guard case .spread(let text, let start, let end) = resolved else {
            return XCTFail("expected spread on envelope")
        }
        XCTAssertEqual(text, "hello there everyone")
        XCTAssertEqual(start, 1.0)
        XCTAssertEqual(end, 2.0)
        let words = FluidOfflineTimings.words(from: resolved)
        XCTAssertEqual(words.count, 3)
        XCTAssertEqual(words[0].start, 1.0)
        XCTAssertEqual(words[2].end, 2.0)
    }

    func testOfflineTimingsFullClipSpreadWhenTimingsEmpty() {
        let resolved = FluidOfflineTimings.resolve(
            transcript: "one two", timings: [], clipDuration: 8)
        guard case .spread(let text, let start, let end) = resolved else {
            return XCTFail("expected full-clip spread")
        }
        XCTAssertEqual(text, "one two")
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 8)
        let words = FluidOfflineTimings.words(from: resolved)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].start, 0)
        XCTAssertEqual(words[1].end, 8)
    }
}
