import XCTest
@testable import Parley

/// Apple Speech emits whole-word tokens without SentencePiece ▁ markers.
/// These tests lock the spacing contract so we don't regress to
/// `Thescreenitselfis…` again.
final class DiarizationAttributionSpeechTests: XCTestCase {

    func testReconstruct_plainWords_joinsWithSpaces() {
        let text = DiarizationAttribution.reconstruct(["The", "screen", "itself", "is", "very", "anti-reflective."])
        XCTAssertEqual(text, "The screen itself is very anti-reflective.")
    }

    func testReconstruct_leadingSpaceWords_preservesSpaces() {
        let text = DiarizationAttribution.reconstruct(["The", " screen", " itself", " is"])
        XCTAssertEqual(text, "The screen itself is")
    }

    func testReconstruct_sentencePiece_stillWorks() {
        let text = DiarizationAttribution.reconstruct(["▁The", "▁screen", "▁itself"])
        XCTAssertEqual(text, "The screen itself")
    }

    func testSegments_plainSpeechWords_keepSpaces() {
        let tokens: [DiarizationAttribution.Token] = [
            .init(text: "The", start: 0.0, end: 0.2),
            .init(text: " screen", start: 0.2, end: 0.5),
            .init(text: " itself", start: 0.5, end: 0.8),
            .init(text: " is", start: 0.8, end: 1.0),
            .init(text: " very", start: 1.0, end: 1.3),
            .init(text: " anti-reflective.", start: 1.3, end: 1.8),
        ]
        var runIds: [String: UUID] = [:]
        let segs = DiarizationAttribution.segments(
            tokens: tokens, turns: [], resolvedNames: [:], runIds: &runIds)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "The screen itself is very anti-reflective.")
    }

    func testSegments_plainWordsWithoutMarkers_stillSpaced() {
        // Defensive path: even if Speech forgot leading spaces, reconstruct
        // must not glue words together.
        let tokens: [DiarizationAttribution.Token] = [
            .init(text: "So", start: 0.0, end: 0.2),
            .init(text: "maybe", start: 0.2, end: 0.4),
            .init(text: "I'm", start: 0.4, end: 0.6),
            .init(text: "not", start: 0.6, end: 0.8),
        ]
        var runIds: [String: UUID] = [:]
        let segs = DiarizationAttribution.segments(
            tokens: tokens, turns: [], resolvedNames: [:], runIds: &runIds)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "So maybe I'm not")
    }
}
