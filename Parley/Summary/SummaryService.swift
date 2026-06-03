import Foundation
import AppKit
import UserNotifications

/// Drives the single (Claude, raw-prompt) meeting-summary flow asynchronously:
/// generate in the background → stage the result → user reviews in History → commit to the
/// vault (or discard / regenerate). Replaces the old skill-based auto-run. "Ready for review"
/// is represented purely by the presence of a staging file (`.staging/<transcript>.md`), so it
/// survives app restarts; in-flight jobs are tracked in `jobs` only while running.
@MainActor
final class SummaryService: ObservableObject {
    enum JobState: Equatable {
        case pending(since: Date)
        case failed(String)
    }

    /// Per-transcript live job state, keyed by transcript path. Absent = not running
    /// (either never summarized, or already staged/committed).
    @Published private(set) var jobs: [String: JobState] = [:]

    private let store: TranscriptStore
    private var queue: [TranscriptItem] = []
    private var isRunning = false

    init(store: TranscriptStore) {
        self.store = store
        // Ask once so we can ping the user when a background summary is ready to review.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func state(for item: TranscriptItem) -> JobState? { jobs[item.id] }

    /// The staging file where a transcript's pending summary lives (exists ⇒ ready to review).
    @MainActor static func stagingURL(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension().lastPathComponent
        return AppPaths.stagingURL.appendingPathComponent("\(base).md")
    }

    // MARK: Run

    /// Queue a background summary for `item` (no-op if already pending or already staged).
    func summarize(_ item: TranscriptItem) {
        guard jobs[item.id] == nil else { return }
        if FileManager.default.fileExists(atPath: Self.stagingURL(for: item.url).path) { return }
        jobs[item.id] = .pending(since: Date())
        queue.append(item)
        runNext()
    }

    func regenerate(_ item: TranscriptItem) {
        try? FileManager.default.removeItem(at: Self.stagingURL(for: item.url))
        jobs[item.id] = nil
        store.refresh()
        summarize(item)
    }

    func discard(_ item: TranscriptItem) {
        try? FileManager.default.removeItem(at: Self.stagingURL(for: item.url))
        jobs[item.id] = nil
        store.refresh()
    }

    private func runNext() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let item = queue.removeFirst()
        let settings = AppSettings.shared
        let built = SummaryPromptBuilder.build(
            template: settings.summaryPromptTemplate,
            transcriptURL: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            destination: item.meta.filing,
            contactsURL: settings.contactsURL)
        let binary = settings.claudeBinaryPath
        let model = settings.claudeModel
        let staged = Self.stagingURL(for: item.url)
        AppLog.log("Summary: started for \(item.url.lastPathComponent) (model=\(model))", category: "summary")

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.runClaude(binary: binary, prompt: built.prompt, model: model)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let text):
                    do {
                        AppPaths.ensureDirectory(staged.deletingLastPathComponent())
                        try text.write(to: staged, atomically: true, encoding: .utf8)
                        self.jobs[item.id] = nil
                        Self.notifyReady(title: item.meta.title)
                        AppLog.log("Summary: ready for review — \(staged.lastPathComponent)", category: "summary")
                    } catch {
                        self.jobs[item.id] = .failed("Couldn't write the summary: \(error.localizedDescription)")
                    }
                case .failure(let reason):
                    self.jobs[item.id] = .failed(reason)
                    AppLog.log("Summary: failed for \(item.url.lastPathComponent) — \(reason)", category: "summary")
                }
                self.store.refresh()
                self.isRunning = false
                self.runNext()
            }
        }
    }

    /// Runs `claude -p` (raw, no skill/tools; extended thinking left ON) and returns the note text.
    private nonisolated static func runClaude(binary: String, prompt: String, model: String) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try ClaudeRunner.makeRawSummaryProcess(binaryPath: binary, prompt: prompt, model: model)
        } catch {
            return .failure(error.localizedDescription)
        }
        do { try built.process.run() }
        catch { return .failure("Failed to launch claude: \(error.localizedDescription)") }
        let outData = built.stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = built.stderr.fileHandleForReading.readDataToEndOfFile()
        built.process.waitUntilExit()
        guard built.process.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(err.isEmpty ? "claude exited with code \(built.process.terminationStatus)" : String(err.prefix(240)))
        }
        let text = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .failure("claude produced no output.") : .success(text)
    }

    private enum RunResult { case success(String); case failure(String) }

    /// Local notification when a summary lands, since runs take a minute or two and the user
    /// may be in another tab/app.
    private static func notifyReady(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Summary ready to review"
        content.body = title.isEmpty ? "A meeting summary is ready in History → Review." : title
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Commit

    /// Files the staged summary into the vault at `destination`, marks the transcript processed,
    /// removes the staging file, and opens the note in Obsidian. Returns the written note URL.
    @discardableResult
    func commit(_ item: TranscriptItem, destination: String) -> URL? {
        let staged = Self.stagingURL(for: item.url)
        guard let body = try? String(contentsOf: staged, encoding: .utf8) else {
            AppLog.log("Summary: commit failed — no staged file for \(item.url.lastPathComponent)", category: "summary")
            return nil
        }
        let vault = AppSettings.shared.vaultURL
        let dest = destination.trimmingCharacters(in: .whitespaces)
        let folder = dest.isEmpty ? vault : vault.appendingPathComponent(dest, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let safeTitle = item.meta.title.replacingOccurrences(of: "/", with: "-")
        var noteURL = folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle).md")
        // Don't clobber an existing note unless it's this transcript's own note.
        if FileManager.default.fileExists(atPath: noteURL.path), item.meta.note != noteURL.path {
            var n = 2
            repeat {
                noteURL = folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle) (\(n)).md")
                n += 1
            } while FileManager.default.fileExists(atPath: noteURL.path)
        }

        let content = Self.composeNote(item: item, destination: dest, body: body)
        do {
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Summary: commit write failed — \(error.localizedDescription)", category: "summary")
            return nil
        }
        let moved = store.moveToProcessed(item, notePath: noteURL.path)
        try? FileManager.default.removeItem(at: staged)
        jobs[item.id] = nil

        // The committed summary + the raw transcript make the session audio redundant —
        // delete it (and its session folder) to reclaim disk, and clear the `audio` link.
        // Permanent (not Trash): this is an automatic, opt-in disk reclaim, not a user-initiated
        // delete they might want to undo. The session-dir guard is shared via MeetingFiles.
        if AppSettings.shared.deleteAudioAfterFiling, let audio = item.meta.audio, !audio.isEmpty {
            if let sessionDir = MeetingFiles.sessionDir(forAudioPath: audio) {
                try? FileManager.default.removeItem(at: sessionDir)   // mic/system/mixed.caf + manifest
            } else {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: audio))
            }
            TranscriptWriter.updateFrontmatter(at: moved) { $0.audio = nil }
            AppLog.log("Summary: deleted session audio after filing", category: "summary")
        }

        openInObsidian(noteURL)
        AppLog.log("Summary: committed \(noteURL.lastPathComponent) → \(dest.isEmpty ? "(vault root)" : dest)", category: "summary")
        store.refresh()
        return noteURL
    }

    private static func composeNote(item: TranscriptItem, destination: String, body: String) -> String {
        if body.hasPrefix("---\n") || body.hasPrefix("---\r\n") { return body }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["---", "title: \(item.meta.title)", "date: \(df.string(from: item.meta.date))"]
        if !item.meta.attendees.isEmpty {
            lines.append("attendees:")
            for a in item.meta.attendees { lines.append("  - \(a)") }
        }
        if !destination.isEmpty { lines.append("filing: \(destination)") }
        lines.append("source: parley-summary")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    private func openInObsidian(_ url: URL) {
        if let obs = NotesGenerator.obsidianOpenURL(for: url, configuredVault: AppSettings.shared.vaultURL) {
            NSWorkspace.shared.open(obs)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
