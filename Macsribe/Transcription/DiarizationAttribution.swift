import Foundation

/// Engine-agnostic "diarization-first" speaker attribution.
///
/// The diarized turns are authoritative for WHO spoke WHEN; ASR words are grouped
/// onto them. Ported (intentionally duplicated, not refactored) from the proven
/// algorithm in `FluidAudioEngine` so the WhisperKit + SpeakerKit engine can reuse
/// it without touching the FluidAudio path. See the FluidAudio attribution-bug
/// history: word starts are marked by `▁` (streaming ASR) OR a leading space
/// (offline batch ASR); gap words map to the NEAREST turn BOUNDARY (not midpoint).
enum DiarizationAttribution {

    /// One ASR word/sub-word with its time span.
    struct Token: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// One diarized speaker turn.
    struct Turn: Sendable {
        let speakerId: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// A token begins a new word if it starts with the SentencePiece ▁ marker
    /// (streaming) or a literal leading space (offline batch ASR).
    static func isWordStart(_ text: String) -> Bool {
        text.hasPrefix("\u{2581}") || text.hasPrefix(" ")
    }

    /// Rebuild readable text from sub-word tokens (▁ → space).
    static func reconstruct(_ tokens: [String]) -> String {
        tokens.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The diarized speaker active at time `t`: the turn containing it, else the turn
    /// with the NEAREST BOUNDARY (a long turn's midpoint is far from its edges, so
    /// nearest-midpoint mis-assigns gap words to distant long turns).
    static func speakerAt(_ t: TimeInterval, turns: [Turn]) -> String? {
        guard !turns.isEmpty else { return nil }
        for d in turns where t >= d.start && t <= d.end { return d.speakerId }
        var best: (id: String, dist: TimeInterval)?
        for d in turns {
            let dist = min(abs(t - d.start), abs(t - d.end))
            if dist < (best?.dist ?? .greatestFiniteMagnitude) { best = (d.speakerId, dist) }
        }
        return best?.id
    }

    /// Build display segments: group tokens into whole words, assign each word the
    /// diarized speaker at its midpoint, and merge consecutive same-speaker words into
    /// one segment. `runIds` caches stable row ids keyed by run start so resolving a
    /// speaker name later doesn't churn SwiftUI identities. Pass the engine's
    /// `resolvedNames` (speakerId → person) to fill in named labels.
    static func segments(tokens: [Token],
                         turns: [Turn],
                         resolvedNames: [String: String],
                         runIds: inout [String: UUID]) -> [Segment] {
        let toks = tokens.sorted { $0.start < $1.start }
        guard !toks.isEmpty else { return [] }

        var words: [[Token]] = []
        for t in toks {
            if words.isEmpty || isWordStart(t.text) { words.append([t]) }
            else { words[words.count - 1].append(t) }
        }

        var runs: [(spk: String?, toks: [Token])] = []
        for w in words {
            let spk = speakerAt((w.first!.start + w.last!.end) / 2, turns: turns)
            if var last = runs.last, last.spk == spk {
                last.toks.append(contentsOf: w); runs[runs.count - 1] = last
            } else {
                runs.append((spk, w))
            }
        }

        var capturedRunIds = runIds
        defer { runIds = capturedRunIds }
        return runs.compactMap { run -> Segment? in
            guard let first = run.toks.first, let last = run.toks.last else { return nil }
            let text = reconstruct(run.toks.map(\.text))
            guard !text.isEmpty else { return nil }
            let key = "df@\(Int(first.start * 100))"
            let id = capturedRunIds[key] ?? {
                let u = UUID(); capturedRunIds[key] = u; return u
            }()
            return Segment(id: id, track: .remote, start: first.start, end: last.end, text: text,
                           confirmed: true, speakerId: run.spk,
                           speakerName: run.spk.flatMap { resolvedNames[$0] })
        }
    }
}
