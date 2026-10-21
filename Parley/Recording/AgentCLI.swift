import Foundation

/// Pieces shared by the headless CLI runners (Claude, Grok, Cursor agent).
enum AgentCLI {
    struct BinaryNotFound: Error, LocalizedError {
        let name: String
        let path: String

        var errorDescription: String? {
            "\(name) CLI not found at \(path). Set its path in Settings → Summary."
        }
    }

    static func requireExecutable(_ path: String, name: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw BinaryNotFound(name: name, path: path)
        }
    }

    /// Outcome of parsing a `--output-format json` response body.
    enum JSONResult: Equatable {
        case text(String)
        case error(String)
        case unparseable
    }

    static let authPhrases = [
        "not logged in", "please log in", "unauthorized", "authentication", "sign in", "login required",
    ]

    static func looksLikeAuth(_ text: String, extraPhrases: [String] = []) -> Bool {
        let lower = text.lowercased()
        return (authPhrases + extraPhrases).contains { lower.contains($0) }
    }

    /// Agents sometimes narrate ("Searching for the full transcript…") before the note
    /// even with tools disabled. Drop everything before the first standard section heading.
    static func sanitizeNoteText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["## Attendees", "## Executive Summary"] {
            if let range = trimmed.range(of: marker, options: .caseInsensitive) {
                return String(trimmed[range.lowerBound...])
            }
        }
        return trimmed
    }
}
