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

/// Builds a `CustomVocabularyContext` from meeting metadata for offline rescoring.
enum FluidVocabularyBuilder {
    /// Attendee names + title tokens (when boosting is enabled and terms exist).
    static func build(attendees: String, meetingTitle: String, enabled: Bool) -> [CustomVocabularyTerm] {
        guard enabled else { return [] }
        var seen = Set<String>()
        var terms: [CustomVocabularyTerm] = []
        func add(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3 else { return }
            let key = t.lowercased()
            guard seen.insert(key).inserted else { return }
            terms.append(CustomVocabularyTerm(text: t, weight: 10))
        }
        for name in TranscriptWriter.splitAttendees(attendees) {
            // Full name and each token (e.g. "Anna Krylova" → both parts).
            add(name)
            for part in name.split(whereSeparator: { $0.isWhitespace }) {
                add(String(part))
            }
        }
        for word in meetingTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            add(String(word))
        }
        return terms
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
