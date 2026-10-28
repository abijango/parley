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
        /// Voiceprint hint or unique-attendee suggestion — never auto-committed.
        var guessedName: String?
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

    /// Fold speaker `id` into `target`: `id`'s lines take the target's label (its name,
    /// or `Speaker {target}`) and the two entries become one with summed talk time.
    /// Returns the relabeled body, or `body` unchanged when either id is missing.
    static func merge(_ id: String, into target: String, in cache: inout SpeakerCache, body: String) -> String {
        guard id != target,
              let from = cache.speakers.firstIndex(where: { $0.id == id }),
              let to = cache.speakers.firstIndex(where: { $0.id == target }) else { return body }
        let name = cache.speakers[to].resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name?.isEmpty == false ? name! : "Speaker \(target)"
        cache.speakers[to].talkSeconds += cache.speakers[from].talkSeconds
        cache.speakers.remove(at: from)
        return relabel(body, assignments: [id: label])
    }

    /// Undo auto-identification for attendees the user removed: each removed name that
    /// resolves to exactly one diarized speaker has its transcript lines turned back into
    /// `Speaker {id}` and its `resolvedName` cleared, so the speaker can be named again.
    /// A name shared by several speakers is left alone — its lines can't be told apart.
    /// Matching suggestions are dropped too. Returns the relabeled body.
    static func unassign(_ names: [String], in cache: inout SpeakerCache, body: String) -> String {
        let removed = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                               .filter { !$0.isEmpty })
        func key(_ name: String?) -> String? {
            name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var out = body
        for name in removed {
            let matches = cache.speakers.indices.filter { key(cache.speakers[$0].resolvedName) == name }
            guard matches.count == 1, let i = matches.first,
                  let label = cache.speakers[i].resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { continue }
            out = out.replacingOccurrences(of: "] \(label):", with: "] Speaker \(cache.speakers[i].id):")
            cache.speakers[i].resolvedName = nil
        }
        for i in cache.speakers.indices {
            if let guess = key(cache.speakers[i].guessedName), removed.contains(guess) {
                cache.speakers[i].guessedName = nil
            }
        }
        return out
    }

    /// Merge user-assigned names with any auto-resolved names already on the cache.
    /// User assignments win on id collision so a rename sticks.
    static func mergedAssignments(cache: SpeakerCache?, user: [String: String]) -> [String: String] {
        var out = user
        guard let cache else { return out }
        for s in cache.speakers {
            guard let name = s.resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            if out[s.id] == nil { out[s.id] = name }
        }
        return out
    }

    /// Write `assignments` into each matching speaker's `resolvedName` (in place).
    mutating func applyAssignments(_ assignments: [String: String]) {
        for i in speakers.indices {
            if let raw = assignments[speakers[i].id] {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { speakers[i].resolvedName = name }
            }
        }
    }
}
