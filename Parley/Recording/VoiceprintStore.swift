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
    /// `model` scopes matching to prints from the same embedding model — different
    /// engines (FluidAudio `wespeaker_v2` vs SpeakerKit `pyannote_v3`) use different,
    /// non-comparable embedding spaces, so they never cross-match. Defaults to the
    /// FluidAudio model so existing callers are unchanged.
    func match(_ embedding: [Float], threshold: Double,
               model: String = VoiceprintStore.embeddingModel) -> (voiceprint: Voiceprint, score: Double)? {
        let q = Self.normalized(embedding)
        var best: (Voiceprint, Double)?
        for vp in voiceprints
        where vp.embeddingModel == model && vp.embeddingDim == q.count {
            // Best similarity over the centroid AND each enrolled sample — more
            // forgiving of cross-session variation than the averaged centroid alone
            // (the averaged centroid can dilute a match for a less-consistent voice).
            var score = Double(Self.dot(q, Self.normalized(vp.centroid)))
            for e in vp.embeddings { score = max(score, Double(Self.dot(q, Self.normalized(e)))) }
            if score >= threshold, score > (best?.1 ?? -Double.infinity) { best = (vp, score) }
        }
        return best.map { (voiceprint: $0.0, score: $0.1) }
    }

    /// The saved voiceprint with this name (case-insensitive), if any.
    func voiceprint(named name: String) -> Voiceprint? {
        voiceprints.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Mutations (persist immediately)

    /// Speaker-embedding model id used by the WhisperKit + SpeakerKit engine
    /// (pyannote v3 embedder, 256-d). Distinct from FluidAudio's `wespeaker_v2`.
    /// This string is an OPAQUE SCOPE KEY for matching — do NOT "correct" it to a
    /// version number, or every previously-enrolled SpeakerKit print stops matching.
    static let speakerKitEmbeddingModel = "pyannote_v3"

    /// Embedding models that some CURRENT engine still uses. A print tagged with
    /// any of these is valid — it matches under its own engine — and must never be
    /// treated as stale. Both spaces are live: FluidAudio (`wespeaker_v2`) and
    /// WhisperKit+SpeakerKit (`pyannote_v3`). Treating a `pyannote_v3` print as
    /// "outdated" and regenerating it via FluidAudio silently destroys it (there is
    /// no SpeakerKit clip-embedding path to put it back).
    static let currentEmbeddingModels: Set<String> = [embeddingModel, speakerKitEmbeddingModel]

    @discardableResult
    func enroll(name: String, embedding: [Float],
                model: String = VoiceprintStore.embeddingModel) -> Voiceprint {
        let e = Self.normalized(embedding)
        let now = Date()
        let vp = Voiceprint(
            id: UUID(), name: name, embeddings: [e], centroid: e, sampleCount: 1,
            createdAt: now, updatedAt: now,
            embeddingModel: model, embeddingDim: e.count,
            schemaVersion: Voiceprint.currentSchemaVersion, audioSample: nil)
        voiceprints.append(vp)
        save()
        return vp
    }

    /// Append an embedding to an existing identity, recompute its centroid, and
    /// refine the voiceprint (accuracy improves as more confident samples land).
    func addSample(to id: UUID, embedding: [Float]) {
        guard let idx = voiceprints.firstIndex(where: { $0.id == id }) else { return }
        var vp = voiceprints[idx]
        vp.embeddings.append(Self.normalized(embedding))
        vp.centroid = Self.normalized(Self.mean(vp.embeddings))
        vp.sampleCount = vp.embeddings.count
        vp.updatedAt = Date()
        voiceprints[idx] = vp
        save()
    }

    /// Retain a short enrollment audio clip (for re-enrollment on model upgrade).
    func attachAudioSample(to id: UUID, samples: [Float]) {
        guard !samples.isEmpty, let idx = voiceprints.firstIndex(where: { $0.id == id }) else { return }
        voiceprints[idx].audioSample = samples.withUnsafeBytes { Data($0) }
        save()
    }

    /// Voiceprints whose embeddings were made by a model NO current engine uses
    /// (e.g. an old FluidAudio embedder superseded on upgrade) — their vectors are
    /// no longer comparable and should be regenerated from the retained clip.
    ///
    /// Scoped by model id, NOT by "is it the FluidAudio model": a `pyannote_v3`
    /// print is current (it matches under WhisperKit+SpeakerKit), so it is never
    /// stale. The previous wespeaker-only definition flagged every pyannote print
    /// as outdated and the re-enroll path then converted them to wespeaker —
    /// silently wiping WhisperKit identification for those people.
    var staleVoiceprints: [Voiceprint] {
        voiceprints.filter { !Self.currentEmbeddingModels.contains($0.embeddingModel) }
    }

    /// One clip-backed source print per distinct name (case-insensitive) that has NO
    /// print in `model`'s embedding space — the candidates for rebuilding that engine's
    /// voiceprints from retained clips (e.g. pyannote prints lost to an earlier
    /// re-enroll). Names that already have a `model` print are excluded, so applying
    /// the result and re-querying yields an empty set (idempotent).
    func clipSourcesMissing(model: String) -> [Voiceprint] {
        let have = Set(voiceprints.filter { $0.embeddingModel == model }.map { $0.name.lowercased() })
        var sources: [String: Voiceprint] = [:]
        for vp in voiceprints where vp.audioSample != nil && !have.contains(vp.name.lowercased()) {
            sources[vp.name.lowercased()] = sources[vp.name.lowercased()] ?? vp
        }
        return Array(sources.values)
    }

    /// Replace a voiceprint's vectors with freshly-computed embeddings (e.g. from its
    /// retained clip after a model upgrade), re-stamping the current model/dim/schema.
    /// Identity (id, name, createdAt) and the retained clip are preserved.
    func reEnroll(_ id: UUID, embeddings: [[Float]]) {
        guard let idx = voiceprints.firstIndex(where: { $0.id == id }), !embeddings.isEmpty else { return }
        let normed = embeddings.map { Self.normalized($0) }
        let old = voiceprints[idx]
        voiceprints[idx] = Voiceprint(
            id: old.id, name: old.name, embeddings: normed,
            centroid: Self.normalized(Self.mean(normed)), sampleCount: normed.count,
            createdAt: old.createdAt, updatedAt: Date(),
            embeddingModel: Self.embeddingModel, embeddingDim: normed.first?.count ?? Self.embeddingDim,
            schemaVersion: Voiceprint.currentSchemaVersion, audioSample: old.audioSample)
        save()
        AppLog.log("Re-enrolled voiceprint \(old.name): \(normed.count) embedding(s), model \(Self.embeddingModel)", category: "record")
    }

    /// Raw retained clip samples for a voiceprint (decoded from the stored Data).
    func clipSamples(_ id: UUID) -> [Float]? {
        guard let vp = voiceprints.first(where: { $0.id == id }), let data = vp.audioSample else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
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

    // MARK: - Export / import (backup + sharing)

    /// Serialise the whole store to JSON. With a non-empty `passphrase`, the JSON is
    /// passphrase-wrapped (AES-GCM); otherwise it's plain JSON (portable, inspectable).
    func exportData(passphrase: String?) throws -> Data {
        let json = try JSONEncoder().encode(voiceprints)
        if let passphrase, !passphrase.isEmpty { return try VoiceprintCrypto.encrypt(json, passphrase: passphrase) }
        return json
    }

    /// Import voiceprints from exported data, merging by id (imported overwrites a
    /// matching id; new ones are added). Auto-detects plain JSON vs passphrase-wrapped.
    @discardableResult
    func importData(_ data: Data, passphrase: String?) throws -> Int {
        let json: Data
        if let prints = try? JSONDecoder().decode([Voiceprint].self, from: data) {
            return merge(prints)   // plain JSON
        } else if let passphrase, !passphrase.isEmpty {
            json = try VoiceprintCrypto.decrypt(data, passphrase: passphrase)
        } else {
            throw VoiceprintCrypto.CryptoError.malformed   // encrypted but no passphrase given
        }
        return merge(try JSONDecoder().decode([Voiceprint].self, from: json))
    }

    private func merge(_ incoming: [Voiceprint]) -> Int {
        for vp in incoming {
            if let idx = voiceprints.firstIndex(where: { $0.id == vp.id }) { voiceprints[idx] = vp }
            else { voiceprints.append(vp) }
        }
        save()
        return incoming.count
    }

    // MARK: - Persistence

    func load() {
        guard let raw = try? Data(contentsOf: fileURL) else { voiceprints = []; return }
        // Encrypted at rest; transparently migrate a legacy plaintext store.
        if let plain = try? VoiceprintCrypto.decrypt(raw),
           let prints = try? JSONDecoder().decode([Voiceprint].self, from: plain) {
            voiceprints = prints
        } else if let prints = try? JSONDecoder().decode([Voiceprint].self, from: raw) {
            voiceprints = prints
            AppLog.log("Migrating \(prints.count) voiceprint(s) to encrypted storage", category: "model")
            save()   // re-write encrypted
        } else {
            voiceprints = []
        }
        let withClips = voiceprints.filter { $0.audioSample != nil }.count
        let byModel = Dictionary(grouping: voiceprints, by: \.embeddingModel).mapValues(\.count)
        AppLog.log("Loaded \(voiceprints.count) voiceprint(s), \(withClips) with audio clip(s), \(staleVoiceprints.count) stale; by model: \(byModel)", category: "model")
    }

    private func save() {
        AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(voiceprints) else { return }
        guard let sealed = try? VoiceprintCrypto.encrypt(data) else {
            AppLog.log("Failed to encrypt voiceprint store — not saving plaintext", category: "model"); return
        }
        try? sealed.write(to: fileURL, options: .atomic)
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
