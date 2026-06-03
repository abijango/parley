import Foundation

/// A persistent speaker voiceprint — **biometric data**. Stored outside the vault
/// and (Phase 6) encrypted at rest.
///
/// Embeddings are NOT portable across embedding models, so `embeddingModel`,
/// `embeddingDim`, and `schemaVersion` are recorded with every record. If FluidAudio's
/// embedding model changes on upgrade, prints with a different `embeddingModel` are
/// ignored for matching and must be re-enrolled — `sampleAudioPaths` retains short
/// enrollment snippets so vectors can be regenerated without starting over.
struct Voiceprint: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Accumulated enrollment embeddings (each L2-normalized).
    var embeddings: [[Float]]
    /// Mean of `embeddings`, L2-normalized — what `match` compares against.
    var centroid: [Float]
    var sampleCount: Int
    let createdAt: Date
    var updatedAt: Date
    /// Embedding model identity these vectors came from (e.g. "wespeaker_v2").
    let embeddingModel: String
    let embeddingDim: Int
    let schemaVersion: Int
    /// A short retained enrollment clip (raw 16 kHz mono Float32 bytes), kept so the
    /// voiceprint can be regenerated if the embedding model changes on upgrade. It
    /// lives inside the encrypted store. Optional for backward-compatible decoding.
    var audioSample: Data?

    static let currentSchemaVersion = 1
}
