import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summary engine backed by Apple's on-device Foundation Model (runs on the Neural
/// Engine, macOS 26+). Fully offline, no download we manage, no model choice. The model
/// has a modest context window, so long transcripts are truncated to fit (with a note).
/// Availability depends on Apple Intelligence being enabled in System Settings.
@MainActor
final class AppleFoundationSummaryEngine: SummaryEngine {
    let kind = SummaryEngineKind.appleFoundation

    /// The on-device model's context window is small (~4096 tokens, shared by input AND
    /// output). Budget conservatively: cap the prompt to ~8k chars (~2.3–2.7k tokens) and
    /// bound the response (below) so input+output stays under the window. Long transcripts
    /// are truncated (with a note) — a fair full-length Apple summary would need
    /// map-reduce chunking, which is a future enhancement.
    private let maxPromptChars = 8_000
    private let maxResponseTokens = 1_000

    func availability() async -> SummaryAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(Self.describe(reason))
            @unknown default:
                return .unavailable("Apple model unavailable.")
            }
        } else {
            return .unavailable("Apple Intelligence requires macOS 26 or later.")
        }
        #else
        return .unavailable("FoundationModels isn't available in this build.")
        #endif
    }

    func summarize(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                let reason = await availability().reason ?? "Apple model unavailable."
                throw SummaryError.engineUnavailable(reason)
            }
            let (trimmed, wasTruncated) = Self.fit(prompt, maxChars: maxPromptChars)
            if wasTruncated {
                AppLog.log("Summary(Apple): transcript truncated to ~\(maxPromptChars) chars to fit context", category: "summary")
            }
            do {
                let session = LanguageModelSession()
                let options = GenerationOptions(maximumResponseTokens: maxResponseTokens)
                let response = try await session.respond(to: trimmed, options: options)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw SummaryError.generationFailed("Apple model produced no output.") }
                return wasTruncated
                    ? text + "\n\n> _Note: the transcript was truncated to fit the on-device model's context window._"
                    : text
            } catch let e as SummaryError {
                throw e
            } catch {
                throw SummaryError.generationFailed(error.localizedDescription)
            }
        } else {
            throw SummaryError.engineUnavailable("Apple Intelligence requires macOS 26 or later.")
        }
        #else
        throw SummaryError.engineUnavailable("FoundationModels isn't available in this build.")
        #endif
    }

    /// Truncates the prompt to a char budget, preserving the leading instructions and
    /// cutting from the end of the transcript (kept whole-line where possible).
    private static func fit(_ prompt: String, maxChars: Int) -> (String, Bool) {
        guard prompt.count > maxChars else { return (prompt, false) }
        let head = String(prompt.prefix(maxChars))
        // Cut back to the last newline so we don't end mid-line.
        if let nl = head.lastIndex(of: "\n") {
            return (String(head[..<nl]), true)
        }
        return (head, true)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "The Apple model is still downloading — try again shortly."
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence."
        @unknown default:
            return "Apple model unavailable."
        }
    }
    #endif
}
