import Foundation

/// Orchestrates running the summary engines (Claude / Apple / Qwen) over ONE transcript
/// with the SAME shared prompt, so their outputs can be compared side-by-side. Engines run
/// sequentially (one-by-one) to avoid GPU/ANE contention and keep memory bounded. Holds the
/// per-engine state the compare view renders. This is an evaluation tool — filing happens
/// via the Approve step, not here.
@MainActor
final class SummaryComparison: ObservableObject {
    enum RunState: Equatable {
        case idle
        case running
        case done
        case failed(String)
        case unavailable(String)
    }

    struct Result: Identifiable {
        let kind: SummaryEngineKind
        var id: String { kind.rawValue }
        var state: RunState = .idle
        var markdown: String = ""
        var elapsed: TimeInterval?
    }

    /// All engines, in display order (left-to-right).
    let allKinds: [SummaryEngineKind] = [.claude, .appleFoundation, .qwenLocal]

    /// Engines the user has enabled for the comparison (subset of `allKinds`).
    var kinds: [SummaryEngineKind] { allKinds.filter { settings.isSummaryEngineEnabled($0) } }

    @Published private(set) var results: [Result]
    @Published private(set) var isRunning = false
    @Published private(set) var transcriptURL: URL?
    @Published private(set) var title = ""

    private var attendees = ""
    private var destination = ""
    private let settings: AppSettings
    private let summarizer: SummarizerManager
    private var runToken = 0

    init(settings: AppSettings, summarizer: SummarizerManager) {
        self.settings = settings
        self.summarizer = summarizer
        self.results = [Result(kind: .claude), Result(kind: .appleFoundation), Result(kind: .qwenLocal)]
    }

    func configure(transcriptURL: URL, title: String, attendees: String, destination: String) {
        self.transcriptURL = transcriptURL
        self.title = title
        self.attendees = attendees
        self.destination = destination
    }

    func result(for kind: SummaryEngineKind) -> Result {
        results.first { $0.kind == kind } ?? Result(kind: kind)
    }

    // MARK: Runs

    /// Run every engine in sequence (one-by-one), all on the same freshly-built prompt.
    func runAll() {
        guard let transcriptURL else { return }
        runToken += 1
        let token = runToken
        isRunning = true
        for k in kinds { updateState(k) { $0.state = .idle; $0.markdown = ""; $0.elapsed = nil } }
        Task {
            let prompt = buildPrompt(transcriptURL)
            for k in kinds {
                if token != runToken { return }
                await runOne(k, prompt: prompt, token: token)
            }
            if token == runToken { isRunning = false }
        }
    }

    /// Re-run a single engine (e.g. after editing the prompt). Cancels any in-flight batch
    /// but leaves already-completed results in place.
    func run(_ kind: SummaryEngineKind) {
        guard let transcriptURL else { return }
        runToken += 1
        let token = runToken
        isRunning = true
        updateState(kind) { $0.state = .idle; $0.markdown = ""; $0.elapsed = nil }
        Task {
            let prompt = buildPrompt(transcriptURL)
            await runOne(kind, prompt: prompt, token: token)
            if token == runToken { isRunning = false }
        }
    }

    func cancel() {
        runToken += 1
        isRunning = false
        for k in kinds { updateState(k) { if $0.state == .running { $0.state = .idle } } }
    }

    // MARK: Internals

    private func buildPrompt(_ url: URL) -> String {
        SummaryPromptBuilder.build(
            template: settings.summaryPromptTemplate,
            transcriptURL: url,
            attendees: attendees,
            destination: destination,
            contactsURL: settings.contactsURL
        ).prompt
    }

    private func engine(_ kind: SummaryEngineKind) -> SummaryEngine {
        switch kind {
        case .claude: return ClaudeSummaryEngine(settings: settings)
        case .appleFoundation: return AppleFoundationSummaryEngine()
        case .qwenLocal: return QwenLocalSummaryEngine(settings: settings, manager: summarizer)
        }
    }

    private func runOne(_ kind: SummaryEngineKind, prompt: String, token: Int) async {
        updateState(kind) { $0.state = .running; $0.markdown = ""; $0.elapsed = nil }
        let engine = engine(kind)
        if case .unavailable(let reason) = await engine.availability() {
            if token == runToken { updateState(kind) { $0.state = .unavailable(reason) } }
            return
        }
        let start = Date()
        do {
            let md = try await engine.summarize(prompt: prompt)
            guard token == runToken else { return }
            let elapsed = Date().timeIntervalSince(start)
            updateState(kind) { $0.markdown = md; $0.state = .done; $0.elapsed = elapsed }
            AppLog.log("Summary(\(kind.title)): done in \(String(format: "%.1f", elapsed))s", category: "summary")
        } catch {
            guard token == runToken else { return }
            let reason = (error as? SummaryError)?.errorDescription ?? error.localizedDescription
            updateState(kind) { $0.state = .failed(reason); $0.elapsed = Date().timeIntervalSince(start) }
            AppLog.log("Summary(\(kind.title)): failed — \(reason)", category: "summary")
        }
    }

    private func updateState(_ kind: SummaryEngineKind, _ mutate: (inout Result) -> Void) {
        guard let i = results.firstIndex(where: { $0.kind == kind }) else { return }
        mutate(&results[i])
    }
}
