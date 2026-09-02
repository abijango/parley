import Foundation

/// Voiceprint hint-band and unique-attendee leftovers — suggestions only, never auto-commit.
@MainActor
enum SpeakerGuessResolver {
    static let hintBandLower = 0.45

    /// Fill `guessedName` on cache speakers that remain unnamed after auto-identify.
    static func applyGuesses(to cache: inout SpeakerCache,
                             attendees: String,
                             voiceprints: VoiceprintStore,
                             identificationThreshold: Double) {
        let hintUpper = identificationThreshold
        let attendeeNames = TranscriptWriter.splitAttendees(attendees)
        var usedAttendees = Set<String>()
        for s in cache.speakers {
            if let n = s.resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                usedAttendees.insert(n.lowercased())
            }
        }
        let unused = attendeeNames.filter { !usedAttendees.contains($0.lowercased()) }
        let uniqueAttendee = unused.count == 1 ? unused[0] : nil
        var assignedUniqueAttendee = false

        for i in cache.speakers.indices {
            guard cache.speakers[i].resolvedName == nil else { continue }
            let centroid = cache.speakers[i].centroid
            if !centroid.isEmpty,
               let best = voiceprints.match(centroid, threshold: 0, model: cache.embeddingModelID),
               best.score >= hintBandLower, best.score < hintUpper {
                cache.speakers[i].guessedName = best.voiceprint.name
                continue
            }
            if let uniqueAttendee, !assignedUniqueAttendee {
                cache.speakers[i].guessedName = uniqueAttendee
                assignedUniqueAttendee = true
            }
        }
    }

    /// Build the SPEAKER HINTS block for summary prompts.
    static func promptBlock(cache: SpeakerCache?, attendees: String) -> String? {
        guard let cache else { return nil }
        var lines: [String] = []
        for s in cache.speakers {
            if s.resolvedName != nil { continue }
            if let guess = s.guessedName?.trimmingCharacters(in: .whitespacesAndNewlines), !guess.isEmpty {
                lines.append("- Speaker \(s.id) may be \(guess) (voiceprint/attendee hint — confirm if unsure)")
            } else {
                lines.append("- Speaker \(s.id) is still unnamed")
            }
        }
        // Attendees not yet tied to a resolved speaker id (best-effort).
        let resolved = Set(cache.speakers.compactMap { $0.resolvedName?.lowercased() })
        let leftover = TranscriptWriter.splitAttendees(attendees).filter { !resolved.contains($0.lowercased()) }
        if !leftover.isEmpty {
            lines.append("- Attendees not clearly mapped in the transcript: \(leftover.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return nil }
        return """
        SPEAKER HINTS (suggestions only — attribute actions to attendees when the transcript is generic; keep "Speaker N" when unsure):
        \(lines.joined(separator: "\n"))
        """
    }

    static func readPromptBlock(sessionDir: URL?, attendees: String) -> String? {
        guard let sessionDir, let cache = SpeakerCache.read(sessionDir) else { return nil }
        return promptBlock(cache: cache, attendees: attendees)
    }
}
