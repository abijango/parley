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

    // MARK: clipSourcesMissing (recovery candidate selection)

    func testClipSourceMissingFindsWespeakerOnlyPersonWithClip() {
        let store = makeStore()
        let vp = store.enroll(name: "Andre", embedding: vec(), model: VoiceprintStore.embeddingModel)
        store.attachAudioSample(to: vp.id, samples: vec())
        let sources = store.clipSourcesMissing(model: VoiceprintStore.speakerKitEmbeddingModel)
        XCTAssertEqual(sources.map(\.name), ["Andre"])
    }

    func testClipSourceMissingExcludesPersonWhoAlreadyHasTargetModel() {
        let store = makeStore()
        let w = store.enroll(name: "Andre", embedding: vec(), model: VoiceprintStore.embeddingModel)
        store.attachAudioSample(to: w.id, samples: vec())
        store.enroll(name: "Andre", embedding: vec(), model: VoiceprintStore.speakerKitEmbeddingModel)
        // Already has a pyannote print → nothing to rebuild (idempotent).
        XCTAssertTrue(store.clipSourcesMissing(model: VoiceprintStore.speakerKitEmbeddingModel).isEmpty)
    }

    func testClipSourceMissingSkipsPrintsWithoutClip() {
        let store = makeStore()
        store.enroll(name: "NoClip", embedding: vec(), model: VoiceprintStore.embeddingModel)
        XCTAssertTrue(store.clipSourcesMissing(model: VoiceprintStore.speakerKitEmbeddingModel).isEmpty,
                      "Can't rebuild without a retained clip")
    }

    func testClipSourceMissingDedupesByName() {
        let store = makeStore()
        let a = store.enroll(name: "Andre", embedding: vec(), model: VoiceprintStore.embeddingModel)
        store.attachAudioSample(to: a.id, samples: vec())
        let b = store.enroll(name: "andre", embedding: vec(), model: VoiceprintStore.embeddingModel)
        store.attachAudioSample(to: b.id, samples: vec())
        // Two wespeaker prints for the same name (case-insensitive) → one source.
        XCTAssertEqual(store.clipSourcesMissing(model: VoiceprintStore.speakerKitEmbeddingModel).count, 1)
    }
}
