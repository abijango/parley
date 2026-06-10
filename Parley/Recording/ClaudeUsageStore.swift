import Foundation

/// Cumulative tally of the Claude usage **Parley itself has spent** across summary runs,
/// parsed from each `result` event's `usage` + `total_cost_usd` (see
/// `ClaudeStreamParser.Usage`). Shown in Settings → Summary so the user can see what the
/// app has consumed.
///
/// Persisted as plain JSON under Application Support — token counts and an estimated cost
/// aren't secrets, so (unlike `VoiceprintCrypto`) there's no encryption here. `@MainActor`
/// + `ObservableObject` so SwiftUI observes it directly; a `shared` instance backs the app,
/// while `init(fileURL:)` lets tests point at a scratch file.
@MainActor
final class ClaudeUsageStore: ObservableObject {

    /// Running totals since `since` (the first recorded run, or the last `reset()`).
    struct Total: Codable, Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTokens: Int = 0
        var cacheReadTokens: Int = 0
        /// Summed `total_cost_usd` across runs that reported one. An estimate Claude Code
        /// reports — on a subscription there's no incremental charge.
        var costUSD: Double = 0
        /// Number of summary runs recorded.
        var runCount: Int = 0
        /// When this tally began accumulating.
        var since: Date = Date()

        /// All token classes summed — a single headline figure for the UI.
        var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    }

    static let shared = ClaudeUsageStore()

    @Published private(set) var total: Total

    private let fileURL: URL

    /// - Parameter fileURL: where the tally JSON lives. Defaults to
    ///   `…/Application Support/<App>/claude-usage.json`.
    init(fileURL: URL = ClaudeUsageStore.defaultFileURL) {
        self.fileURL = fileURL
        self.total = ClaudeUsageStore.load(from: fileURL) ?? Total()
    }

    nonisolated static var defaultFileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("claude-usage.json")
    }

    /// Fold one run's usage into the running totals and persist. No-op for nil usage.
    func record(_ usage: ClaudeStreamParser.Usage?) {
        guard let usage else { return }
        total.inputTokens += usage.inputTokens
        total.outputTokens += usage.outputTokens
        total.cacheCreationTokens += usage.cacheCreationTokens
        total.cacheReadTokens += usage.cacheReadTokens
        if let cost = usage.costUSD { total.costUSD += cost }
        total.runCount += 1
        save()
    }

    /// Zero the tally and restart the `since` clock.
    func reset() {
        total = Total(since: Date())
        save()
    }

    // MARK: Persistence

    private func save() {
        do {
            AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(total)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.log("ClaudeUsageStore: failed to save — \(error.localizedDescription)", category: "summary")
        }
    }

    private static func load(from url: URL) -> Total? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Total.self, from: data)
    }
}
