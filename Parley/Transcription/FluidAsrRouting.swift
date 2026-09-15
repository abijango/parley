import Foundation
import FluidAudio

/// ASR stack used for one FluidAudio session. Snapshot this at record-start so the
/// offline re-pass cannot pick a different model from live Settings.
enum FluidAsrProfile: String, Codable, Equatable, Sendable {
    case parakeetUnified
    case parakeetV2
    case parakeetV3
}

enum FluidAsrBinding {
    static func profile(
        useUnified: Bool,
        language: String,
        version: FluidParakeetVersion
    ) -> FluidAsrProfile {
        if useUnified && FluidAsrRouting.isEnglishStreamingLanguage(language) {
            return .parakeetUnified
        }
        return version == .v2 ? .parakeetV2 : .parakeetV3
    }

    @MainActor
    static func profile(from settings: AppSettings) -> FluidAsrProfile {
        profile(
            useUnified: settings.useParakeetUnified,
            language: settings.liveStreamingLanguage,
            version: settings.parakeetVersion)
    }

    static func profile(stored: FluidAsrProfile?, fallback: FluidAsrProfile) -> FluidAsrProfile {
        stored ?? fallback
    }

    @MainActor
    static func resolved(stored: FluidAsrProfile?, settings: AppSettings) -> FluidAsrProfile {
        profile(stored: stored, fallback: profile(from: settings))
    }
}

/// Chooses between Parakeet Unified (English) and Nemotron multilingual + TDT v3.
@MainActor
enum FluidAsrRouting {
    /// True when the session should use Parakeet Unified streaming + offline batch.
    static func usesParakeetUnified(settings: AppSettings) -> Bool {
        FluidAsrBinding.profile(from: settings) == .parakeetUnified
    }

    /// English `liveStreamingLanguage` values (`en`, `en-US`, `en-GB`, …).
    nonisolated static func isEnglishStreamingLanguage(_ code: String) -> Bool {
        let lc = code.lowercased()
        if lc == "en" { return true }
        return lc.hasPrefix("en-") || lc.hasPrefix("en_")
    }

    /// Unified streaming variant — 2080 ms default per FluidAudio benchmarks.
    static func unifiedStreamingVariant() -> StreamingModelVariant {
        .parakeetUnified2080ms
    }

    /// Maps the Nemotron latency tier to the closest Unified tier when the user
    /// switches back to multilingual mid-settings (informational only).
    static func unifiedVariant(matching tier: FluidStreamingTier) -> StreamingModelVariant {
        switch tier {
        case .ms560: return .parakeetUnified320ms
        case .ms1120: return .parakeetUnified640ms
        case .ms2240: return .parakeetUnified1120ms
        case .ms4480: return .parakeetUnified2080ms
        }
    }

    /// Human-readable label for Settings / transport bar.
    static func displayModelName(settings: AppSettings) -> String {
        if usesParakeetUnified(settings: settings) {
            return "Parakeet Unified"
        }
        return settings.parakeetVersion.displayName
    }
}

enum FluidVocabularyPolicy {
    static func shouldLoad(enabled: Bool, terms: [CustomVocabularyTerm]) -> Bool {
        enabled && !terms.isEmpty
    }
}

/// FluidAudio may rescore display text while leaving emission timings on the original pieces.
enum FluidOfflineTimings {
    struct Word: Equatable, Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    enum Resolved: Equatable, Sendable {
        case native([Word])
        case spread(text: String, start: TimeInterval, end: TimeInterval)
    }

    static func resolve(
        transcript: String,
        timings: [TokenTiming],
        clipDuration: TimeInterval
    ) -> Resolved {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if timings.isEmpty {
            return .spread(text: trimmed, start: 0, end: clipDuration)
        }
        if let words = matchingEmissions(transcript: trimmed, timings: timings) {
            return .native(words)
        }
        let groups = buildWordTimings(from: timings)
        if let words = zipRescored(transcript: trimmed, groups: groups) {
            return .native(words)
        }
        return envelopeSpread(transcript: trimmed, timings: timings, groups: groups)
    }

    static func words(from resolved: Resolved) -> [Word] {
        switch resolved {
        case .native(let words):
            return words
        case .spread(let text, let start, let end):
            return evenSpread(text: text, start: start, end: end)
        }
    }

    nonisolated private static func matchingEmissions(
        transcript: String, timings: [TokenTiming]
    ) -> [Word]? {
        guard reconstruct(timings.map(\.token)) == transcript else { return nil }
        return timings.map { Word(text: $0.token, start: $0.startTime, end: $0.endTime) }
    }

    nonisolated private static func zipRescored(
        transcript: String, groups: [WordTiming]
    ) -> [Word]? {
        let display = transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard display.count == groups.count, !groups.isEmpty else { return nil }
        return zip(display, groups).map { word, timed in
            Word(text: "\u{2581}" + word, start: timed.startTime, end: timed.endTime)
        }
    }

    nonisolated private static func envelopeSpread(
        transcript: String, timings: [TokenTiming], groups: [WordTiming]
    ) -> Resolved {
        let start = groups.first?.startTime ?? timings[0].startTime
        let end = groups.last?.endTime ?? timings[timings.count - 1].endTime
        return .spread(text: transcript, start: start, end: end)
    }

    nonisolated private static func reconstruct(_ tokens: [String]) -> String {
        tokens.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func evenSpread(
        text: String, start: TimeInterval, end: TimeInterval
    ) -> [Word] {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !parts.isEmpty else { return [] }
        let step = max(0, end - start) / Double(parts.count)
        return parts.enumerated().map { i, w in
            let s = start + step * Double(i)
            let e = i == parts.count - 1 ? end : start + step * Double(i + 1)
            return Word(text: "\u{2581}" + w, start: s, end: e)
        }
    }
}

/// Builds a `CustomVocabularyContext` from meeting metadata for offline rescoring.
///
/// ## Why this is more careful than it looks
///
/// Vocabulary terms do not merely *hint* to the recogniser — the rescorer
/// **overwrites** any span of speech whose string similarity to a term clears a
/// threshold. FluidAudio's default threshold is 0.52, i.e. a 52% match is enough
/// to replace what somebody actually said.
///
/// Multi-token terms ("Allegra Hensley") are safe: they are long and rarely
/// resemble ordinary speech. **Single tokens are not.** Measured on a real
/// 73-minute recording (see `docs/VOCABULARY_OVERFIRE.md`), single-token terms at
/// the default threshold produced:
///
/// * `Hensley` ← "sense"        (×14 in one transcript)
/// * `Granados` ← "grand"
/// * `Ceylan` ← "certain"
/// * `Steps` ← "stop" / "staff"  (from the meeting title "Cursor/SpaceX Next Steps")
/// * `Next` ← "net"              (likewise from the title)
/// * `Carlos` ← "you're talking about", "of revenue for us", "Fargo", "Chris"
///
/// The last one is the worst: it does not swap word-for-word, it eats whole
/// phrases. "Wells Fargo" became "Wells Carlos" and "Chris" became "Carlos" —
/// silently corrupting an account name and a person's identity.
///
/// So: full names keep the library default, and every single token is held to
/// `singleTokenMinSimilarity`. That value is not a guess — 0.52 and 0.75 both
/// still corrupted real audio; 0.85 was clean across every clip tested.
enum FluidVocabularyBuilder {

    /// Similarity a **single-token** term must clear before it may overwrite speech.
    /// Verified empirically: 0.52 (library default) and 0.75 both corrupt; 0.85 is clean.
    static let singleTokenMinSimilarity: Float = 0.85

    /// Shortest single token allowed into the vocabulary. Short tokens collide with
    /// far too much ordinary speech ("Mir" ← "mix", "Gleb" ← "glib").
    static let singleTokenMinLength = 5

    /// Single tokens that are ordinary English are never safe to boost, however long.
    /// Meeting titles are the main source of these ("Next Steps", "Weekly Update").
    static let unsafeSingleTokens: Set<String> = [
        // meeting-title furniture
        "next", "step", "steps", "call", "sync", "chat", "notes", "note", "intro",
        "demo", "prep", "plan", "plans", "recap", "catch", "standup", "check",
        "quick", "touch", "base", "kickoff", "kick", "followup", "follow", "up",
        "meeting", "meetings", "weekly", "daily", "monthly", "update", "updates",
        "review", "session", "discussion", "discuss", "agenda", "brief", "briefing",
        "status", "report", "board", "team", "teams", "group", "working", "work",
        "first", "final", "draft", "part", "round", "deep", "dive", "one", "two",
        // generic business words that show up in titles
        "business", "customer", "client", "project", "program", "product", "partner",
        "partnership", "strategy", "revenue", "sales", "delivery", "training",
        "account", "accounts", "pipeline", "commercial", "contract", "proposal",
        // pronouns / stopwords that a fuzzy match loves
        "and", "the", "for", "with", "from", "that", "this", "they", "them", "you",
        "your", "our", "his", "her", "its", "are", "was", "were", "has", "have",
    ]

    /// Why a candidate was kept or dropped — surfaced in Settings so the user can
    /// see what the recogniser is actually being told to look for.
    enum Tier: Equatable, Sendable {
        /// Multi-token name. Library default similarity.
        case fullName
        /// Single token, held to `singleTokenMinSimilarity`.
        case strictToken
        /// Excluded, with a human-readable reason.
        case excluded(String)
    }

    struct Candidate: Equatable, Sendable {
        let text: String
        let tier: Tier
        var isIncluded: Bool {
            if case .excluded = tier { return false }
            return true
        }
    }

    /// Attendee names + title tokens (when boosting is enabled and terms exist).
    static func build(attendees: String, meetingTitle: String, enabled: Bool) -> [CustomVocabularyTerm] {
        candidates(attendees: attendees, meetingTitle: meetingTitle, enabled: enabled)
            .compactMap { candidate in
                switch candidate.tier {
                case .fullName:
                    return CustomVocabularyTerm(text: candidate.text, weight: 10)
                case .strictToken:
                    return CustomVocabularyTerm(
                        text: candidate.text, weight: 10,
                        minSimilarity: singleTokenMinSimilarity)
                case .excluded:
                    return nil
                }
            }
    }

    /// The same derivation as `build`, but keeping the rejects and the reason they
    /// were rejected. Drives the Settings preview.
    static func candidates(
        attendees: String, meetingTitle: String, enabled: Bool
    ) -> [Candidate] {
        guard enabled else { return [] }
        var seen = Set<String>()
        var out: [Candidate] = []

        func consider(_ raw: String, fromTitle: Bool) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let key = t.lowercased()
            guard seen.insert(key).inserted else { return }

            let isMultiToken = t.contains(where: { $0.isWhitespace })
            if isMultiToken {
                // Full names are safe — long, and they rarely resemble real speech.
                out.append(Candidate(text: t, tier: .fullName))
                return
            }
            if t.count < singleTokenMinLength {
                out.append(Candidate(
                    text: t,
                    tier: .excluded("too short — under \(singleTokenMinLength) characters it "
                                    + "matches too much ordinary speech")))
                return
            }
            if unsafeSingleTokens.contains(key) {
                out.append(Candidate(
                    text: t, tier: .excluded("ordinary English — boosting it would overwrite "
                                             + "real words")))
                return
            }
            if fromTitle && !(t.first?.isUppercase ?? false) {
                out.append(Candidate(
                    text: t, tier: .excluded("title word, not a proper noun")))
                return
            }
            out.append(Candidate(text: t, tier: .strictToken))
        }

        for name in TranscriptWriter.splitAttendees(attendees) {
            // Full name first, then each part (e.g. "Anna Krylova" → both parts).
            // The parts are the dangerous ones and are gated by `consider`.
            consider(name, fromTitle: false)
            for part in name.split(whereSeparator: { $0.isWhitespace }) {
                consider(String(part), fromTitle: false)
            }
        }
        for word in meetingTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            consider(String(word), fromTitle: true)
        }
        return out
    }

    /// Tokenize terms with the CTC spotter models (required for offline rescoring).
    static func loadContext(terms: [CustomVocabularyTerm]) async -> (CustomVocabularyContext, CtcModels)? {
        guard !terms.isEmpty else { return nil }
        do {
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let ctcTokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m))
            let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = ctcTokenizer.encode(term.text)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(
                    text: term.text, weight: term.weight, aliases: term.aliases,
                    tokenIds: nil, ctcTokenIds: ids, minSimilarity: term.minSimilarity)
            }
            guard !tokenized.isEmpty else { return nil }
            let ctx = CustomVocabularyContext(terms: tokenized)
            return (ctx, ctcModels)
        } catch {
            AppLog.log("Fluid vocabulary load failed: \(error.localizedDescription)", category: "record")
            return nil
        }
    }
}
