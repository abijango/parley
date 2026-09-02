import XCTest
@testable import Parley

@MainActor
final class SpeakerGuessResolverTests: XCTestCase {
    func testUniqueAttendeeBecomesGuess() {
        var cache = SpeakerCache(
            embeddingModelID: "wespeaker_v2",
            mixedCafName: "mixed.caf",
            speakers: [
                .init(id: "1", resolvedName: nil, guessedName: nil,
                      talkSeconds: 30, sampleStart: 0, sampleEnd: 5, firstLine: "Hi", centroid: [])
            ])
        let store = VoiceprintStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("test-vp-\(UUID().uuidString).json"))
        SpeakerGuessResolver.applyGuesses(
            to: &cache, attendees: "Alice, Bob", voiceprints: store,
            identificationThreshold: 0.6)
        XCTAssertEqual(cache.speakers[0].guessedName, nil) // two unused — no unique leftover
    }

    func testUniqueAttendeeIsSuggestedForOnlyOneUnnamedSpeaker() {
        var cache = SpeakerCache(
            embeddingModelID: "wespeaker_v2",
            mixedCafName: "mixed.caf",
            speakers: [
                .init(id: "1", resolvedName: nil, guessedName: nil,
                      talkSeconds: 30, sampleStart: 0, sampleEnd: 5, firstLine: "Hi", centroid: []),
                .init(id: "2", resolvedName: nil, guessedName: nil,
                      talkSeconds: 20, sampleStart: 5, sampleEnd: 10, firstLine: "Hello", centroid: [])
            ])
        let store = VoiceprintStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("test-vp-\(UUID().uuidString).json"))

        SpeakerGuessResolver.applyGuesses(
            to: &cache, attendees: "Alice", voiceprints: store,
            identificationThreshold: 0.6)

        XCTAssertEqual(cache.speakers.compactMap(\.guessedName), ["Alice"])
    }

    func testPromptBlockListsUnnamed() {
        let cache = SpeakerCache(
            embeddingModelID: "wespeaker_v2",
            mixedCafName: "mixed.caf",
            speakers: [
                .init(id: "2", resolvedName: nil, guessedName: "Priya",
                      talkSeconds: 10, sampleStart: 0, sampleEnd: 3, firstLine: "OK", centroid: [])
            ])
        let block = SpeakerGuessResolver.promptBlock(cache: cache, attendees: "Alice")
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("Priya") == true)
    }
}
