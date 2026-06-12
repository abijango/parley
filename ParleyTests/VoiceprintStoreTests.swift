import XCTest
@testable import Parley

/// Coverage for the model-scoped "stale" definition. The bug this guards against:
/// a wespeaker-only `staleVoiceprints` flagged every pyannote (WhisperKit/SpeakerKit)
/// print as outdated, and the re-enroll path then regenerated them via FluidAudio —
/// silently converting them to wespeaker_v2 and wiping WhisperKit identification.
@MainActor
final class VoiceprintStoreTests: XCTestCase {

    /// Each test gets its own throwaway store file so persistence doesn't bleed across runs.
    private func makeStore() -> VoiceprintStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).json")
        return VoiceprintStore(fileURL: url)
    }

    private func vec() -> [Float] { Array(repeating: Float(1), count: VoiceprintStore.embeddingDim) }

    func testPyannotePrintIsNeverStale() {
        let store = makeStore()
        store.enroll(name: "Andre", embedding: vec(), model: VoiceprintStore.speakerKitEmbeddingModel)
        XCTAssertTrue(store.staleVoiceprints.isEmpty,
                      "A pyannote_v3 print is current and must not be flagged stale")
    }

    func testWespeakerPrintIsNeverStale() {
        let store = makeStore()
        store.enroll(name: "Lucy", embedding: vec(), model: VoiceprintStore.embeddingModel)
        XCTAssertTrue(store.staleVoiceprints.isEmpty)
    }

    func testUnknownModelPrintIsStale() {
        let store = makeStore()
        store.enroll(name: "Old", embedding: vec(), model: "wespeaker_v1")
        XCTAssertEqual(store.staleVoiceprints.map(\.name), ["Old"],
                       "A model no current engine uses should still be flagged for re-enrollment")
    }

    func testMixedStoreOnlyFlagsUnknownModels() {
        let store = makeStore()
        store.enroll(name: "Andre", embedding: vec(), model: VoiceprintStore.speakerKitEmbeddingModel)
        store.enroll(name: "Lucy", embedding: vec(), model: VoiceprintStore.embeddingModel)
        store.enroll(name: "Old", embedding: vec(), model: "wespeaker_v1")
        XCTAssertEqual(Set(store.staleVoiceprints.map(\.name)), ["Old"])
    }

    func testCurrentModelsAreBothLiveSpaces() {
        XCTAssertTrue(VoiceprintStore.currentEmbeddingModels.contains(VoiceprintStore.embeddingModel))
        XCTAssertTrue(VoiceprintStore.currentEmbeddingModels.contains(VoiceprintStore.speakerKitEmbeddingModel))
    }
}
