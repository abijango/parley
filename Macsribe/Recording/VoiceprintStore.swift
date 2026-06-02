import Foundation

/// Persistent store of speaker voiceprints for **cross-session** speaker
/// identification. JSON-backed (matches the app's file-based persistence and is
/// trivially serialisable for the Phase 6 encrypted export). Lives outside the
/// vault under `Speakers/voiceprints.json` — this is biometric data.
///
/// Distinct from FluidAudio's in-session `clusteringThreshold` (which groups voices
/// within one recording): this store matches a voice to a *saved person* across
/// recordings, gated by a configurable `identificationThreshold` (cosine similarity).
@MainActor
final class VoiceprintStore: ObservableObject {
    @Published private(set) var voiceprints: [Voiceprint] = []

    /// Identity of the embedding model new prints are tagged with (FluidAudio's
    /// diarization embedding). Prints tagged with a different model are skipped when
    /// matching, so an upstream model change can't silently corrupt identification.
    static let embeddingModel = "wespeaker_v2"
    static let embeddingDim = 256

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.speakersDirectory.appendingPathComponent("voiceprints.json")
        load()
    }

    // MARK: - Matching

    /// Best match for `embedding` by cosine similarity vs each stored centroid,
    /// returned only if it clears `threshold`. Prints from a different embedding
    /// model or dimension are ignored.
    func match(_ embedding: [Float], threshold: Double) -> (voiceprint: Voiceprint, score: Double)? {
        let q = Self.normalized(embedding)
        var best: (Voiceprint, Double)?
        for vp in voiceprints
        where vp.embeddingModel == Self.embeddingModel && vp.embeddingDim == q.count {
            let score = Double(Self.dot(q, Self.normalized(vp.centroid)))
            if score >= threshold, score > (best?.1 ?? -Double.infinity) { best = (vp, score) }
        }
        return best.map { (voiceprint: $0.0, score: $0.1) }
    }

    // MARK: - Mutations (persist immediately)

    @discardableResult
    func enroll(name: String, embedding: [Float], audioPath: String? = nil) -> Voiceprint {
        let e = Self.normalized(embedding)
        let now = Date()
        let vp = Voiceprint(
            id: UUID(), name: name, embeddings: [e], centroid: e, sampleCount: 1,
            createdAt: now, updatedAt: now,
            embeddingModel: Self.embeddingModel, embeddingDim: e.count,
            schemaVersion: Voiceprint.currentSchemaVersion,
            sampleAudioPaths: audioPath.map { [$0] } ?? [])
        voiceprints.append(vp)
        save()
        return vp
    }

    /// Append an embedding to an existing identity, recompute its centroid, and
    /// refine the voiceprint (accuracy improves as more confident samples land).
    func addSample(to id: UUID, embedding: [Float], audioPath: String? = nil) {
        guard let idx = voiceprints.firstIndex(where: { $0.id == id }) else { return }
        var vp = voiceprints[idx]
        vp.embeddings.append(Self.normalized(embedding))
        vp.centroid = Self.normalized(Self.mean(vp.embeddings))
        vp.sampleCount = vp.embeddings.count
        vp.updatedAt = Date()
        if let audioPath { vp.sampleAudioPaths.append(audioPath) }
        voiceprints[idx] = vp
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let idx = voiceprints.firstIndex(where: { $0.id == id }) else { return }
        voiceprints[idx].name = name
        voiceprints[idx].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        voiceprints.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { voiceprints = []; return }
        voiceprints = (try? JSONDecoder().decode([Voiceprint].self, from: data)) ?? []
    }

    private func save() {
        AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(voiceprints) else { return }
        try? data.write(to: fileURL, options: .atomic)   // Phase 6 will encrypt this file
    }

    // MARK: - Vector math (cosine over L2-normalized embeddings)

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        var n = 0
        for v in vectors where v.count == acc.count {
            for i in v.indices { acc[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return acc }
        return acc.map { $0 / Float(n) }
    }
}
