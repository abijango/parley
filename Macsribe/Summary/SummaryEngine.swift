import Foundation

/// The three interchangeable summary backends compared side-by-side. Each takes one
/// fully-built, self-contained prompt and returns Markdown — none of them file, read the
/// vault, or run tools (that keeps the comparison fair and the filing uniform via the
/// Approve step). Distinct from the production `NotesGenerator` skill path, which stays.
enum SummaryEngineKind: String, CaseIterable, Identifiable, Equatable {
    case claude            // raw `claude -p` with the shared prompt (no skill/tools)
    case appleFoundation   // Apple Foundation Models, on the ANE (macOS 26+)
    case qwenLocal         // local Qwen via MLX, on the GPU

    var id: String { rawValue }

    /// Short pane title in the comparison view.
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .appleFoundation: return "Apple"
        case .qwenLocal: return "Qwen"
        }
    }

    /// One-line description for settings / tooltips.
    var blurb: String {
        switch self {
        case .claude: return "Anthropic Claude via the CLI — same prompt, no skill or tools."
        case .appleFoundation: return "Apple's on-device model on the Neural Engine (needs Apple Intelligence enabled)."
        case .qwenLocal: return "Local Qwen running on the GPU via MLX — fully offline."
        }
    }
}

/// Whether an engine can run right now, with a human-readable reason when it can't
/// (shown in the compare view / settings — e.g. "enable Apple Intelligence", "download the model").
enum SummaryAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { if case .available = self { return true }; return false }
    var reason: String? { if case .unavailable(let r) = self { return r }; return nil }
}

enum SummaryError: LocalizedError {
    case engineUnavailable(String)
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): return m
        case .generationFailed(let m): return m
        case .cancelled: return "Cancelled."
        }
    }
}

/// A summary backend. Implementations are `@MainActor` for simple state ownership;
/// heavy work hops to a background task internally.
@MainActor
protocol SummaryEngine: AnyObject {
    var kind: SummaryEngineKind { get }
    /// Cheap readiness check for the UI; may load nothing.
    func availability() async -> SummaryAvailability
    /// Produce a Markdown summary from the fully-built prompt. Throws `SummaryError`.
    func summarize(prompt: String) async throws -> String
}
