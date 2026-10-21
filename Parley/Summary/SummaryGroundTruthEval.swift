import Foundation

/// Runs the selected summarizer on `SummaryGroundTruth` and scores fact recall
/// against the filed note. Does not stage or file anything.
@MainActor
final class SummaryGroundTruthEval: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
        case finished
    }

    struct Report: Equatable {
        var backendName: String
        var metrics: SummaryRunMetrics
        var score: SummaryAccuracy.Score
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: Report?

    private var generation = UUID()

    func run(backend: SummaryBackend, settings: AppSettings) {
        guard let fixture = SummaryGroundTruth.load(vault: settings.vaultURL) else {
            phase = .failed("The ground-truth meeting isn't in this vault (\(SummaryGroundTruth.transcriptRelativePath)).")
            report = nil
            return
        }
        let terminology = SummaryPromptBuilder.terminologyBlock(
            filingScope: TerminologyStore.customerScope(fromFiling: fixture.destination))
        let built = SummaryPromptBuilder.build(
            template: settings.summaryPromptTemplate,
            transcriptURL: fixture.transcriptURL,
            attendees: fixture.attendees,
            destination: fixture.destination,
            contactsURL: settings.contactsURL,
            contactsFromDB: PeopleStore().contacts(),
            peopleRecords: PeopleStore().all(),
            terminologyBlock: terminology.isEmpty ? nil : terminology,
            visionDigest: nil,
            attachmentUnderstanding: .off)
        let gold = fixture.goldSummary
        let backendName = backend.displayName
        let config = SummaryService.RunnerConfig(settings)
        phase = .running
        report = nil
        let token = UUID()
        generation = token
        Task.detached(priority: .userInitiated) {
            let result = await SummaryService.generateForEval(
                backend: backend,
                prompt: built.prompt,
                config: config)
            let finished: Report?
            let failure: String?
            switch result {
            case .success(let text, let metrics):
                finished = Report(
                    backendName: backendName,
                    metrics: metrics,
                    score: SummaryAccuracy.score(candidate: text, gold: gold))
                failure = nil
            case .failed(let reason):
                finished = nil
                failure = reason
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == token else { return }
                if let finished {
                    self.report = finished
                    self.phase = .finished
                } else {
                    self.phase = .failed(failure ?? "Check failed.")
                }
            }
        }
    }
}
