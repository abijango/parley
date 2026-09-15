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

    private func vocabTexts(attendees: String, title: String) -> Set<String> {
        Set(FluidVocabularyBuilder.build(
            attendees: attendees, meetingTitle: title, enabled: true).map(\.text))
    }

    func testVocabularyBuilderKeepsFullNamesAndLongTokens() {
        let texts = vocabTexts(attendees: "Al, Bob Smith", title: "Q4 OKR")
        XCTAssertTrue(texts.contains("Bob Smith"), "full names are the safe case")
        XCTAssertTrue(texts.contains("Smith"), "distinctive surname of usable length")
        XCTAssertFalse(texts.contains("Al"), "2 characters collides with everything")
        XCTAssertFalse(texts.contains("Bob"), "3 characters is under the single-token floor")
    }

    /// Regression: the 2026-09-14 Cursor recording. Bare name parts overwrote
    /// ordinary speech — "sense" became "Hensley" 14 times in one transcript.
    func testVocabularyBuilderDoesNotBoostShortBareNames() {
        let texts = vocabTexts(
            attendees: "Naufal Mir, Allegra Hensley, Carlos",
            title: "Partnership")
        XCTAssertFalse(texts.contains("Mir"), "\"Mir\" was matching \"mix\"")
        XCTAssertTrue(texts.contains("Naufal Mir"))
        XCTAssertTrue(texts.contains("Allegra Hensley"))
    }

    /// Regression: a lone first name in the contacts file ate whole phrases —
    /// "Wells Fargo" became "Wells Carlos", and "Chris" became "Carlos".
    func testBareSingleTokenNamesAreHeldToStrictSimilarity() {
        let terms = FluidVocabularyBuilder.build(
            attendees: "Carlos Granados", meetingTitle: "Sync", enabled: true)
        let surname = terms.first { $0.text == "Granados" }
        let fullName = terms.first { $0.text == "Carlos Granados" }
        XCTAssertNotNil(surname)
        XCTAssertEqual(surname?.minSimilarity, FluidVocabularyBuilder.singleTokenMinSimilarity,
                       "single tokens must clear the strict threshold before overwriting speech")
        XCTAssertNotNil(fullName)
        XCTAssertNil(fullName?.minSimilarity, "full names keep the library default")
    }

    /// Regression: the meeting title "Cursor/SpaceX Next Steps" injected "Next"
    /// and "Steps", which then overwrote "net" and "stop"/"staff".
    func testVocabularyBuilderRejectsOrdinaryTitleWords() {
        let texts = vocabTexts(attendees: "Naufal Mir", title: "Cursor/SpaceX Next Steps")
        XCTAssertFalse(texts.contains("Next"), "\"Next\" was overwriting \"net\"")
        XCTAssertFalse(texts.contains("Steps"), "\"Steps\" was overwriting \"stop\" and \"staff\"")
        XCTAssertTrue(texts.contains("Cursor"), "distinctive product names stay useful")
        XCTAssertTrue(texts.contains("SpaceX"))
    }

    func testVocabularyCandidatesExplainExclusions() {
        let candidates = FluidVocabularyBuilder.candidates(
            attendees: "Carlos", meetingTitle: "Next Steps", enabled: true)
        let excluded = candidates.filter { !$0.isIncluded }
        XCTAssertFalse(excluded.isEmpty, "Settings needs a reason to show the user")
        for candidate in excluded {
            if case .excluded(let reason) = candidate.tier {
                XCTAssertFalse(reason.isEmpty)
            }
        }
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
