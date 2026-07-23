import Foundation

/// Formats a wall-clock duration for the compare UI (minutes / seconds / microseconds).
enum SummaryDurationFormat {
    /// Examples: `812µs`, `1.234567s`, `2m 5.123456s`
    static func string(from interval: TimeInterval) -> String {
        let microsTotal = max(0, Int((interval * 1_000_000).rounded()))
        let minutes = microsTotal / 60_000_000
        let rem = microsTotal % 60_000_000
        let seconds = rem / 1_000_000
        let micros = rem % 1_000_000
        let frac = String(format: "%06d", micros)
        if minutes > 0 {
            return "\(minutes)m \(seconds).\(frac)s"
        }
        if seconds > 0 || microsTotal >= 1_000_000 {
            return "\(seconds).\(frac)s"
        }
        return "\(micros)µs"
    }
}

/// Orchestrates side-by-side summary runs across every `SummaryBackend` on one shared prompt.
/// Claude is seeded from an already-filed note or a ready-for-review staging draft (no re-run)
/// with an explicit Re-run control.
@MainActor
final class SummaryComparison: ObservableObject {
    enum RunState: Equatable {
        case idle
        case running
        case done
        case seeded          // loaded from filed note or staging — not timed
        case failed(String)
        case unavailable(String)
    }

    /// Where a seeded Claude column came from.
    enum ClaudeSeedSource: Equatable {
        /// Committed vault note (`meta.note`).
        case filedNote
        /// Ready-for-review draft (`.staging/….claude.md` or legacy single-slot staging).
        case stagingDraft
    }

    struct Result: Identifiable, Equatable {
        let backend: SummaryBackend
        var id: String { backend.rawValue }
        var state: RunState = .idle
        var markdown: String = ""
        /// Wall time for a live run; nil when seeded or not yet run.
        var elapsed: TimeInterval?
        var enabled: Bool = true
    }

    @Published private(set) var results: [Result]
    @Published private(set) var isRunning = false
    @Published private(set) var transcriptURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var filingDestination = ""
    @Published private(set) var claudeSeedSource: ClaudeSeedSource?

    private var attendees = ""
    private var filedNoteURL: URL?
    private var runTokens: [SummaryBackend: Int] = [:]
    private var activeCount = 0

    init() {
        self.results = SummaryBackend.allCases.map { Result(backend: $0) }
    }

    func configure(transcriptURL: URL,
                   title: String,
                   attendees: String,
                   destination: String,
                   filedNotePath: String?,
                   stagingDir: URL? = nil) {
        self.transcriptURL = transcriptURL
        self.title = title
        self.attendees = attendees
        self.filingDestination = destination
        if let path = filedNotePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            self.filedNoteURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            self.filedNoteURL = nil
        }
        seedClaudeIfPossible(stagingDir: stagingDir ?? AppPaths.stagingURL)
    }

    func result(for backend: SummaryBackend) -> Result {
        results.first { $0.backend == backend } ?? Result(backend: backend)
    }

    func setEnabled(_ backend: SummaryBackend, _ enabled: Bool) {
        update(backend) { $0.enabled = enabled }
    }

    var enabledBackends: [SummaryBackend] {
        results.filter(\.enabled).map(\.backend)
    }

    // MARK: Seed

    /// Prefer filed (approved) note, else Claude staging draft. Does not clear other columns.
    func seedClaudeIfPossible(stagingDir: URL) {
        claudeSeedSource = nil
        guard let transcriptURL,
              let candidate = Self.claudeSeedCandidate(
                filedNoteURL: filedNoteURL,
                transcriptURL: transcriptURL,
                stagingDir: stagingDir),
              let raw = try? String(contentsOf: candidate.url, encoding: .utf8) else { return }
        let body = Self.summaryBodyForCompare(fromFiledNote: raw)
        guard !body.isEmpty else { return }
        claudeSeedSource = candidate.source
        update(.claude) {
            $0.markdown = body
            $0.state = .seeded
            $0.elapsed = nil
        }
    }

    /// Resolution order: filed note → `.claude.md` staging → legacy single-slot staging
    /// (only when no dual-backend staging files exist).
    nonisolated static func claudeSeedCandidate(
        filedNoteURL: URL?,
        transcriptURL: URL,
        stagingDir: URL
    ) -> (url: URL, source: ClaudeSeedSource)? {
        let fm = FileManager.default
        if let filedNoteURL, fm.fileExists(atPath: filedNoteURL.path) {
            return (filedNoteURL, .filedNote)
        }
        let claudeStaged = SummaryService.stagingURL(
            for: transcriptURL, backend: .claude, stagingDir: stagingDir)
        if fm.fileExists(atPath: claudeStaged.path) {
            return (claudeStaged, .stagingDraft)
        }
        let dual = SummaryService.allStagedSummaries(for: transcriptURL, stagingDir: stagingDir)
            .filter { $0.backend != nil }
        let legacy = SummaryService.legacyStagingURL(for: transcriptURL, stagingDir: stagingDir)
        if dual.isEmpty, fm.fileExists(atPath: legacy.path) {
            return (legacy, .stagingDraft)
        }
        return nil
    }

    /// Strip frontmatter, inline raw transcript, and wiki-link footers so the Claude pane
    /// shows only the comparable summary sections.
    nonisolated static func summaryBodyForCompare(fromFiledNote text: String) -> String {
        var s = SummaryService.strippingRawTranscriptSection(text)
        s = SummaryService.strippingRawTranscriptWikiLink(s)
        s = SummaryPromptBuilder.strippingFrontmatter(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Runs

    /// Run every *enabled* backend (concurrent). Claude uses a live run even if seeded.
    func runAllEnabled() {
        for backend in enabledBackends {
            run(backend, forceLive: true)
        }
    }

    /// Run one backend. For Claude, `forceLive` false keeps seeded content unless empty.
    func run(_ backend: SummaryBackend, forceLive: Bool = true) {
        guard let transcriptURL else { return }
        if backend == .claude, !forceLive, case .seeded = result(for: .claude).state {
            return
        }
        runTokens[backend, default: 0] += 1
        let token = runTokens[backend]!
        if backend == .claude { claudeSeedSource = nil }
        update(backend) { $0.state = .running; $0.markdown = ""; $0.elapsed = nil }
        bumpActive(+1)
        let prompt = buildPrompt(transcriptURL)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await Self.generate(backend: backend, prompt: prompt)
            await MainActor.run {
                guard let self, self.runTokens[backend] == token else { return }
                switch outcome {
                case .success(let text, let elapsed):
                    self.update(backend) {
                        $0.markdown = text
                        $0.state = .done
                        $0.elapsed = elapsed
                    }
                    AppLog.log("Compare(\(backend.displayName)): done in \(SummaryDurationFormat.string(from: elapsed))",
                               category: "summary")
                case .failure(let reason, let elapsed):
                    self.update(backend) {
                        $0.state = .failed(reason)
                        $0.elapsed = elapsed
                    }
                    AppLog.log("Compare(\(backend.displayName)): failed — \(reason)", category: "summary")
                }
                self.bumpActive(-1)
            }
        }
    }

    func cancelAll() {
        for b in SummaryBackend.allCases {
            runTokens[b, default: 0] += 1
            if case .running = result(for: b).state {
                update(b) { $0.state = .idle }
            }
        }
        activeCount = 0
        isRunning = false
    }

    // MARK: Internals

    private func bumpActive(_ delta: Int) {
        activeCount = max(0, activeCount + delta)
        isRunning = activeCount > 0
    }

    private func buildPrompt(_ url: URL) -> String {
        SummaryPromptBuilder.build(
            template: AppSettings.shared.summaryPromptTemplate,
            transcriptURL: url,
            attendees: attendees,
            destination: filingDestination,
            contactsURL: AppSettings.shared.contactsURL
        ).prompt
    }

    private func update(_ backend: SummaryBackend, _ mutate: (inout Result) -> Void) {
        guard let i = results.firstIndex(where: { $0.backend == backend }) else { return }
        var copy = results
        mutate(&copy[i])
        results = copy
    }

    private enum GenOutcome: Sendable {
        case success(String, TimeInterval)
        case failure(String, TimeInterval?)
    }

    /// Runs one backend off the main actor; measures wall time around the call.
    private nonisolated static func generate(backend: SummaryBackend, prompt: String) async -> GenOutcome {
        let settings = await MainActor.run { (
            claudeBinary: AppSettings.shared.claudeBinaryPath,
            claudeModel: AppSettings.shared.claudeModel,
            grokBinary: AppSettings.shared.grokBinaryPath,
            grokModel: AppSettings.shared.grokModel,
            cursorBinary: AppSettings.shared.cursorBinaryPath
        ) }
        let start = Date()
        switch backend {
        case .claude:
            let r = await Task.detached {
                SummaryService.runClaudeForCompare(
                    binary: settings.claudeBinary,
                    prompt: prompt,
                    model: settings.claudeModel)
            }.value
            return map(r, start: start)
        case .grok:
            let r = await Task.detached {
                SummaryService.runGrokForCompare(
                    binary: settings.grokBinary,
                    prompt: prompt,
                    model: settings.grokModel)
            }.value
            return map(r, start: start)
        case .local:
            let startLocal = start
            do {
                let text: String = try await Task { @MainActor in
                    await RecordingController.shared.prepareForLocalSummary()
                    return try await LocalSummaryRunner.shared.summarize(prompt: prompt)
                }.value
                let elapsed = Date().timeIntervalSince(startLocal)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty
                    ? .failure("Local model produced no output.", elapsed)
                    : .success(cleaned, elapsed)
            } catch {
                return .failure(error.localizedDescription, Date().timeIntervalSince(startLocal))
            }
        case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
            let model = backend.rawValue
            let r = await Task.detached {
                SummaryService.runCursorForCompare(
                    binary: settings.cursorBinary,
                    prompt: prompt,
                    model: model)
            }.value
            return map(r, start: start)
        }
    }

    private nonisolated static func map(_ r: SummaryService.CompareGenerateResult, start: Date) -> GenOutcome {
        let elapsed = Date().timeIntervalSince(start)
        switch r {
        case .ok(let text): return .success(text, elapsed)
        case .failed(let reason): return .failure(reason, elapsed)
        }
    }
}
