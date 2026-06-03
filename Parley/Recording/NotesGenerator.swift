import Foundation
import AppKit

/// Drives a single `claude -p` notes-generation run with a cancellable process
/// and a state machine the UI observes. Streams `stream-json` events so progress
/// ("Reading transcript…", "Writing note…") shows live. Owns the `Process` so
/// `cancel()` can terminate it.
@MainActor
final class NotesGenerator: ObservableObject {
    enum State: Equatable {
        case idle
        case running(since: Date)
        case finished(noteURL: URL?, summary: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Live activity feed during a run (newest last), capped.
    @Published private(set) var activity: [String] = []
    /// Set when a re-process run finishes successfully: the existing real note
    /// and the freshly-staged candidate, so the UI can diff and Accept/Discard.
    @Published private(set) var pendingDiff: PendingDiff?

    /// A finished re-process awaiting the user's Accept/Discard decision.
    struct PendingDiff: Equatable {
        let existingURL: URL   // the real note to overwrite on Accept
        let stagedURL: URL     // the staged candidate Claude just produced
    }

    private var process: Process?
    private var runToken = 0
    private let maxActivityLines = 200

    /// Per-run context carried to `complete(...)` so the right finishing path runs.
    private struct RunContext {
        let transcriptURL: URL
        let destination: String
        let vaultURL: URL
        let start: Date
        /// reprocess: diff staged vs this existing note; fresh: nil (write + markProcessed).
        let existingNoteURL: URL?
        /// reprocess: where Claude was told to write; fresh: nil.
        let stagedURL: URL?
        var isReprocess: Bool { existingNoteURL != nil }
    }

    var isRunning: Bool { if case .running = state { return true }; return false }

    // MARK: Run

    /// Fresh run: Claude writes the note to its real filing destination.
    /// On success the caller's `onFreshSuccess` is invoked with the note path so
    /// the transcript can be moved to `Processed/`.
    func generate(transcriptURL: URL?, destination: String, attendees: String, settings: AppSettings,
                  onFreshSuccess: ((_ transcriptURL: URL, _ notePath: String) -> Void)? = nil) {
        run(transcriptURL: transcriptURL, destination: destination, attendees: attendees,
            settings: settings, existingNoteURL: nil, onFreshSuccess: onFreshSuccess)
    }

    /// Re-process run for an already-processed transcript: routes Claude's output
    /// to a hidden staging path (`AppPaths.stagingURL/<id>.md`) instead of
    /// overwriting `existingNoteURL`. On success, `pendingDiff` is populated.
    func reprocess(transcriptURL: URL?, existingNoteURL: URL, destination: String,
                   attendees: String, settings: AppSettings) {
        run(transcriptURL: transcriptURL, destination: destination, attendees: attendees,
            settings: settings, existingNoteURL: existingNoteURL, onFreshSuccess: nil)
    }

    /// Callback fired (main actor) when a fresh run finishes and produced a note.
    private var onFreshSuccess: ((_ transcriptURL: URL, _ notePath: String) -> Void)?

    private func run(transcriptURL: URL?, destination: String, attendees: String, settings: AppSettings,
                     existingNoteURL: URL?,
                     onFreshSuccess: ((_ transcriptURL: URL, _ notePath: String) -> Void)?) {
        guard !isRunning else { return }
        guard let transcriptURL, FileManager.default.fileExists(atPath: transcriptURL.path) else {
            state = .failed("The transcript file is missing (it may have already been processed).")
            return
        }

        let vaultURL = settings.vaultURL
        let isReprocess = existingNoteURL != nil

        // For reprocess, compute the staging file and tell Claude to write THERE.
        var stagedURL: URL?
        var prompt: String
        if isReprocess {
            let stagingDir = AppPaths.stagingURL(vault: vaultURL)
            AppPaths.ensureDirectory(stagingDir)
            let staged = stagingDir.appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent).md")
            try? FileManager.default.removeItem(at: staged)   // clear any leftover
            stagedURL = staged
            prompt = ClaudeRunner.buildReprocessPrompt(
                template: settings.claudePromptTemplate,
                transcriptURL: transcriptURL, destination: destination,
                attendees: attendees, stagedNoteURL: staged)
        } else {
            prompt = ClaudeRunner.buildPrompt(
                template: settings.claudePromptTemplate,
                transcriptURL: transcriptURL, destination: destination, attendees: attendees)
        }

        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try ClaudeRunner.makeProcess(
                binaryPath: settings.claudeBinaryPath, prompt: prompt,
                vaultPath: settings.vaultPath, model: settings.claudeModel)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        runToken += 1
        let token = runToken
        let start = Date()
        process = built.process
        self.onFreshSuccess = onFreshSuccess
        pendingDiff = nil
        activity = [isReprocess ? "Starting Claude (re-process)…" : "Starting Claude…"]
        state = .running(since: start)
        let ctx = RunContext(transcriptURL: transcriptURL, destination: destination,
                             vaultURL: vaultURL, start: start,
                             existingNoteURL: existingNoteURL, stagedURL: stagedURL)
        AppLog.log("Notes: claude \(isReprocess ? "reprocess" : "run") started (model=\(settings.claudeModel)) on \(transcriptURL.lastPathComponent)", category: "claude")

        Task.detached {
            do {
                try built.process.run()
            } catch {
                await self.fail(token: token, message: "Failed to launch claude: \(error.localizedDescription)")
                return
            }

            // Read newline-delimited JSON events incrementally.
            let handle = built.stdout.fileHandleForReading
            var buffer = Data()
            var resultText = ""
            var isError = false
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }   // EOF
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    let event = Self.parse(line)
                    if let r = event.resultText { resultText = r; isError = event.isError ?? false }
                    if !event.lines.isEmpty { await self.append(event.lines, token: token) }
                }
            }
            built.process.waitUntilExit()
            let errText = String(data: built.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            await self.complete(token: token, exit: built.process.terminationStatus,
                                resultText: resultText, isError: isError, errText: errText,
                                context: ctx)
        }
    }

    func cancel() {
        runToken += 1
        process?.terminate()
        process = nil
        onFreshSuccess = nil
        state = .idle
        AppLog.log("Notes: claude run cancelled", category: "claude")
    }

    func reset() {
        if !isRunning { state = .idle; activity = []; pendingDiff = nil }
    }

    // MARK: Re-process commit / discard

    /// Accepts the staged re-process: overwrites the real note with the staged
    /// content, deletes the staging file, and clears `pendingDiff`.
    @discardableResult
    func commitReprocess() -> URL? {
        guard let diff = pendingDiff else { return nil }
        let fm = FileManager.default
        do {
            let staged = try String(contentsOf: diff.stagedURL, encoding: .utf8)
            try staged.write(to: diff.existingURL, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: diff.stagedURL)
            AppLog.log("Notes: reprocess committed → \(diff.existingURL.lastPathComponent)", category: "claude")
        } catch {
            state = .failed("Couldn't apply the re-processed note: \(error.localizedDescription)")
            AppLog.log("Notes: commitReprocess failed: \(error.localizedDescription)", category: "claude")
            return nil
        }
        pendingDiff = nil
        return diff.existingURL
    }

    /// Discards the staged re-process: deletes the staging file, leaves the real
    /// note untouched, and clears `pendingDiff`.
    func discardReprocess() {
        if let diff = pendingDiff {
            try? FileManager.default.removeItem(at: diff.stagedURL)
            AppLog.log("Notes: reprocess discarded", category: "claude")
        }
        pendingDiff = nil
        state = .idle
        activity = []
    }

    // MARK: Updates (main actor)

    private func append(_ lines: [String], token: Int) {
        guard token == runToken else { return }
        activity.append(contentsOf: lines)
        if activity.count > maxActivityLines {
            activity.removeFirst(activity.count - maxActivityLines)
        }
    }

    private func fail(token: Int, message: String) {
        guard token == runToken else { return }
        process = nil
        state = .failed(message)
        AppLog.log("Notes: \(message)", category: "claude")
    }

    private func complete(token: Int, exit: Int32, resultText: String, isError: Bool, errText: String,
                          context ctx: RunContext) {
        guard token == runToken else { return }
        process = nil
        let fresh = onFreshSuccess
        onFreshSuccess = nil

        guard exit == 0, !isError else {
            let detail = resultText.isEmpty ? (errText.isEmpty ? "exit code \(exit)" : errText) : resultText
            state = .failed("Claude failed. \(detail.prefix(240))")
            AppLog.log("Notes: failed (exit \(exit))", category: "claude")
            return
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(ctx.start))
        let summary = resultText.trimmingCharacters(in: .whitespacesAndNewlines)

        if ctx.isReprocess, let existing = ctx.existingNoteURL, let staged = ctx.stagedURL {
            // Prefer the path Claude printed if it points into staging; else the staged URL we asked for.
            let printed = ClaudeRunner.notePath(in: resultText).map { URL(fileURLWithPath: $0) }
            let stagedActual = (printed.map { FileManager.default.fileExists(atPath: $0.path) } == true) ? printed! : staged
            guard FileManager.default.fileExists(atPath: stagedActual.path) else {
                state = .failed("Re-process finished but no staged note was written.")
                AppLog.log("Notes: reprocess produced no staged file", category: "claude")
                return
            }
            pendingDiff = PendingDiff(existingURL: existing, stagedURL: stagedActual)
            state = .finished(noteURL: existing, summary: summary)
            AppLog.log("Notes: reprocess finished in \(elapsed)s, staged=\(stagedActual.lastPathComponent)", category: "claude")
            return
        }

        // Fresh run: locate the produced note and let the caller move the transcript to Processed.
        let noteURL = resolveNoteURL(ClaudeRunner.notePath(in: resultText),
                                     destination: ctx.destination, vaultURL: ctx.vaultURL, after: ctx.start)
        state = .finished(noteURL: noteURL, summary: summary)
        AppLog.log("Notes: finished in \(elapsed)s, note=\(noteURL?.path ?? "unknown")", category: "claude")
        if let noteURL, let fresh { fresh(ctx.transcriptURL, noteURL.path) }
    }

    // MARK: Stream parsing

    private struct Event { var lines: [String] = []; var resultText: String?; var isError: Bool? }

    private nonisolated static func parse(_ data: Data) -> Event {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return Event() }

        switch type {
        case "assistant":
            var out: [String] = []
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for item in content {
                    switch item["type"] as? String {
                    case "tool_use":
                        let name = item["name"] as? String ?? "tool"
                        let input = item["input"] as? [String: Any] ?? [:]
                        out.append("▸ \(name)\(toolDetail(name, input))")
                    case "text":
                        let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { out.append(text.count > 120 ? String(text.prefix(120)) + "…" : text) }
                    default: break
                    }
                }
            }
            return Event(lines: out)
        case "result":
            return Event(resultText: obj["result"] as? String ?? "",
                         isError: (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String) == "error"))
        default:
            return Event()
        }
    }

    private nonisolated static func toolDetail(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "Read", "Write", "Edit":
            if let p = input["file_path"] as? String { return ": \((p as NSString).lastPathComponent)" }
        case "Bash":
            if let c = input["command"] as? String { return ": \(c.prefix(60))" }
        case "Skill":
            if let s = input["command"] as? String ?? input["name"] as? String { return ": \(s)" }
        default: break
        }
        return ""
    }

    private func resolveNoteURL(_ printedPath: String?, destination: String, vaultURL: URL, after start: Date) -> URL? {
        if let printedPath, FileManager.default.fileExists(atPath: printedPath) {
            return URL(fileURLWithPath: printedPath)
        }
        guard !destination.isEmpty else { return nil }
        let folder = vaultURL.appendingPathComponent(destination, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date >= start else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: Opening

    /// Opens the note in Obsidian using the `vault=<id>&file=<relative>` form,
    /// which is far more reliable than `path=<absolute>` (that scans registered
    /// vaults and often reports "vault not found"). Falls back to Finder.
    func openInObsidian(_ url: URL) {
        if let obsidianURL = Self.obsidianOpenURL(for: url, configuredVault: AppSettings.shared.vaultURL) {
            NSWorkspace.shared.open(obsidianURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Builds `obsidian://open?vault=<id|name>&file=<relative>`. Prefers the
    /// vault **id** from Obsidian's own config (always resolves); falls back to
    /// the configured vault's folder name.
    nonisolated static func obsidianOpenURL(for note: URL, configuredVault: URL) -> URL? {
        // Resolve symlinks: the configured vault path is often a symlink (e.g. into
        // iCloud), but Obsidian registers the REAL path — so we must compare resolved.
        let notePath = note.resolvingSymlinksInPath().path

        // 1) Match against Obsidian's registered vaults (use the most specific).
        if let match = registeredVault(containing: notePath) {
            let rel = relativePath(notePath, under: match.path)
            return makeOpenURL(vault: match.id, file: rel)
        }
        // 2) Fall back to the app's configured vault, addressed by folder name.
        let base = configuredVault.resolvingSymlinksInPath().path
        if notePath.hasPrefix(base) {
            return makeOpenURL(vault: configuredVault.lastPathComponent,
                               file: relativePath(notePath, under: base))
        }
        return nil
    }

    private nonisolated static func makeOpenURL(vault: String, file: String) -> URL? {
        guard !file.isEmpty,
              let v = vault.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let f = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "obsidian://open?vault=\(v)&file=\(f)")
    }

    private nonisolated static func relativePath(_ path: String, under base: String) -> String {
        var rel = String(path.dropFirst(min(base.count, path.count)))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Reads `~/Library/Application Support/obsidian/obsidian.json` and returns the
    /// registered vault (id + path) whose path is the longest prefix of `notePath`.
    private nonisolated static func registeredVault(containing notePath: String) -> (id: String, path: String)? {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else { return nil }

        var best: (id: String, path: String)?
        for (id, info) in vaults {
            guard let path = info["path"] as? String,
                  notePath == path || notePath.hasPrefix(path.hasSuffix("/") ? path : path + "/") else { continue }
            if best == nil || path.count > best!.path.count { best = (id, path) }
        }
        return best
    }
}
