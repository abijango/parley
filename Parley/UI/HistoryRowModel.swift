import Foundation
import Combine

/// Coarse per-row presentation state for History — cached so list renders don't
/// re-derive pipeline stage, badges, and filters on every body evaluation.
struct HistoryRowModel: Equatable {
    let stage: PipelineStage
    let statusLabel: String
    let statusSeverity: Theme.Severity
    let rowIndicator: RowIndicatorKind?
    let needsYou: Bool
    let isProcessing: Bool

    enum RowIndicatorKind: Equatable {
        case needsSpeakerNames
        case failed
    }

    static func make(stage: PipelineStage) -> HistoryRowModel {
        let (label, severity) = statusPresentation(for: stage)
        let indicator: RowIndicatorKind? = switch stage {
        case .needsSpeakerNames: .needsSpeakerNames
        case .failed: .failed
        default: nil
        }
        return HistoryRowModel(
            stage: stage,
            statusLabel: label,
            statusSeverity: severity,
            rowIndicator: indicator,
            needsYou: stage.needsYou,
            isProcessing: stage.isProcessing
        )
    }

    private static func statusPresentation(for stage: PipelineStage) -> (String, Theme.Severity) {
        switch stage {
        case .detectingSpeakers: return ("Detecting", .info)
        case .summarizing: return ("Summarizing", .info)
        case .queuedForSpeakers, .queuedForSummary: return ("Queued", .info)
        case .needsSpeakerNames: return ("Needs speakers", .warning)
        case .reviewReady: return ("Review", .info)
        case .processed: return ("Processed", .success)
        case .idleUnprocessed: return ("Unprocessed", .warning)
        case .failed(.claudeUsageLimited): return ("Paused", .warning)
        case .failed: return ("Failed", .danger)
        }
    }
}

/// Observes store + queue services and rebuilds row models once per settled change.
@MainActor
final class HistoryRowIndex: ObservableObject {
    @Published private(set) var rows: [String: HistoryRowModel] = [:]
    @Published private(set) var contentMatchIDs: Set<String> = []
    @Published private(set) var isSearchingContents = false

    private var rebuildTask: Task<Void, Never>?
    private var contentSearchTask: Task<Void, Never>?
    private var contentCache: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private weak var store: TranscriptStore?
    private var latestSearchQuery = ""
    private var latestSearchInContents = false

    func observe(
        store: TranscriptStore,
        offline: OfflineProcessingService,
        summary: SummaryService
    ) {
        guard self.store !== store else { return }
        self.store = store
        cancellables.removeAll()

        let trigger = Publishers.MergeMany(
            store.$items.map { _ in () }.eraseToAnyPublisher(),
            offline.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            summary.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )

        trigger
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleRebuild(offline: offline, summary: summary)
            }
            .store(in: &cancellables)

        scheduleRebuild(offline: offline, summary: summary)
    }

    func updateContentSearch(query: String, searchInContents: Bool, items: [TranscriptItem]) {
        latestSearchQuery = query
        latestSearchInContents = searchInContents
        contentSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard searchInContents, !trimmed.isEmpty else {
            isSearchingContents = false
            contentMatchIDs = []
            return
        }

        isSearchingContents = true
        let urls = items.map(\.url)
        contentSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            let cacheSnapshot = contentCache
            let matches = await Task.detached {
                Self.scanContents(urls: urls, query: trimmed, cache: cacheSnapshot)
            }.value
            guard !Task.isCancelled else { return }
            contentCache = matches.cache
            contentMatchIDs = matches.ids
            isSearchingContents = false
        }
    }

    func row(for item: TranscriptItem) -> HistoryRowModel {
        rows[item.id] ?? .make(stage: .idleUnprocessed)
    }

    func stage(for item: TranscriptItem) -> PipelineStage {
        row(for: item).stage
    }

    private func scheduleRebuild(offline: OfflineProcessingService, summary: SummaryService) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self, let store else { return }
            let context = PipelineStage.DeriveContext.make(offline: offline, summary: summary)
            let stages = PipelineStage.deriveBatch(items: store.items, context: context, offline: offline)
            rows = stages.mapValues { HistoryRowModel.make(stage: $0) }
            updateContentSearch(
                query: latestSearchQuery,
                searchInContents: latestSearchInContents,
                items: store.items
            )
        }
    }

    private struct ContentScanResult: Sendable {
        let ids: Set<String>
        let cache: [String: String]
    }

    nonisolated private static func scanContents(
        urls: [URL], query: String, cache: [String: String]
    ) -> ContentScanResult {
        var ids = Set<String>()
        var nextCache = cache
        let fm = FileManager.default
        for url in urls {
            let key = url.path
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            let cacheKey = "\(key)|\(mtime)"
            let text: String
            if let cached = nextCache[cacheKey] {
                text = cached
            } else if let loaded = try? String(contentsOf: url, encoding: .utf8) {
                text = loaded
                nextCache[cacheKey] = loaded
            } else {
                continue
            }
            if text.range(of: query, options: .caseInsensitive) != nil {
                ids.insert(key)
            }
        }
        return ContentScanResult(ids: ids, cache: nextCache)
    }
}
