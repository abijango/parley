import Foundation

/// Persisted result of a finished diarization pass, written next to the recording so the
/// "Assign speakers" review can open INSTANTLY without re-running the (slow) offline pass.
/// The automatic background pass discards its transient engine after writing the
/// transcript; this cache keeps the few things the review actually needs: each speaker's
/// summary + sample offsets (to play "here's Speaker 3" from `mixed.caf`) and centroid
/// embedding (to enrol a voiceprint when you name them). Relabeling the transcript is then
/// a plain text substitution — no engine required.
struct SpeakerCache: Codable, Equatable {
    struct Speaker: Codable, Equatable {
        var id: String              // diarization speaker id → transcript label "Speaker {id}"
        var resolvedName: String?   // auto-identified name, if any
        var talkSeconds: TimeInterval
        var sampleStart: TimeInterval
        var sampleEnd: TimeInterval
        var firstLine: String
        var centroid: [Float]       // embedding for voiceprint enrolment (may be empty)
    }

    /// Embedding model the centroids belong to (voiceprints are keyed by model).
    var embeddingModelID: String
    /// Audio file in the session dir to play samples from (always "mixed.caf").
    var mixedCafName: String
    var speakers: [Speaker]

    static func url(in sessionDir: URL) -> URL { sessionDir.appendingPathComponent("speakers.json") }

    static func read(_ sessionDir: URL) -> SpeakerCache? {
        guard let data = try? Data(contentsOf: url(in: sessionDir)) else { return nil }
        return try? JSONDecoder().decode(SpeakerCache.self, from: data)
    }

    func write(to sessionDir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url(in: sessionDir), options: .atomic)
    }

    /// Relabel a transcript body, substituting `Speaker {id}` labels for assigned names.
    /// Pure; matches the bold speaker label `**[HH:MM:SS] Speaker N:**`. The trailing `:`
    /// in the match keeps "Speaker 1" from also rewriting "Speaker 10".
    static func relabel(_ body: String, assignments: [String: String]) -> String {
        var out = body
        for (id, rawName) in assignments {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out = out.replacingOccurrences(of: "] Speaker \(id):", with: "] \(name):")
        }
        return out
    }
}
