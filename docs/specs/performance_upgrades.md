Top Findings

1. `HistoryView` is doing too much derived work during render, and it compounds with list size. Each item can run `PipelineStage.derive(...)`, `summaryService.state(for:)`, and `StageBarModel.derive(...)` multiple times, while filters and badges also re-scan `store.items`. In practice this means every queue/state publish can trigger repeated per-row recomputation across the entire history list.

```65:107:Parley/UI/HistoryView.swift
private var filteredItems: [TranscriptItem] {
    var base: [TranscriptItem]
    switch filter {
    case .all: base = store.items
    case .processing: base = processingOrderedItems
    case .needsYou: base = store.items.filter { stage($0).needsYou }
    case .done: base = store.items.filter { stage($0) == .processed }
    }
    let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return base }
    return base.filter { matchesSearch($0, query: q) }
}
```

```343:368:Parley/UI/HistoryView.swift
private func row(_ item: TranscriptItem) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
        HStack(spacing: Theme.Spacing.small) {
            Text(item.meta.title)
            Spacer()
            rowIndicator(item)
            statusBadge(item)
        }
        // ...
        if let bar = StageBarModel.derive(item: item, offline: offline, summary: summaryService) {
            SegmentedStageBar(segments: bar.segments, style: .mini)
        }
    }
}
```

This is the strongest UI-side optimization candidate: precompute stage/view-model state once per refresh or once per service publish, instead of recomputing it ad hoc throughout the view tree.

2. Transcript content search is synchronous file I/O on the main actor. Searching with `searchInContents` enabled reads note files inline from the view’s filter path, so typing into search can block the UI as the app opens and scans many markdown files.

```97:106:Parley/UI/HistoryView.swift
private func matchesSearch(_ item: TranscriptItem, query q: String) -> Bool {
    if item.meta.title.lowercased().contains(q) { return true }
    if item.meta.filing.lowercased().contains(q) { return true }
    if item.meta.attendees.contains(where: { $0.lowercased().contains(q) }) { return true }
    if searchInContents, let text = try? String(contentsOf: item.url, encoding: .utf8) {
        return text.range(of: q, options: .caseInsensitive) != nil
    }
    return false
}
```

For a “blazing fast” feel, this should move to a cached/indexed search path or a background query pipeline.

3. Transcript and summary preview loading is also synchronous main-thread file I/O plus markdown parsing. `TranscriptPreviewView` reads full files in `load()`, and `HistoryView.reviewPane(...)` separately reads the staged summary again just to parse inferred affiliations. Large notes or repeated selection changes will show up as sluggish pane switches.

```75:88:Parley/UI/TranscriptPreviewView.swift
private func load() {
    guard let url else { content = nil; loadError = nil; return }
    guard FileManager.default.fileExists(atPath: url.path) else {
        content = nil
        loadError = "This note was moved or processed — open it in Obsidian."
        return
    }
    do {
        content = Self.strippingFrontmatter(try String(contentsOf: url, encoding: .utf8))
        loadError = nil
    } catch {
        content = nil
        loadError = "Couldn't read the note: \(error.localizedDescription)"
    }
}
```

```492:517:Parley/UI/HistoryView.swift
@ViewBuilder private func reviewPane(_ item: TranscriptItem, staged: URL) -> some View {
    let body = (try? String(contentsOf: staged, encoding: .utf8)) ?? ""
    let inferred = InferredAffiliationParser.parseInferred(markdown: body)
    VStack(spacing: 0) {
        // ...
    }
}
```

4. Launch warmup does a lot of synchronous work on the main actor before the app settles: vault refresh, transcript refresh, recovery scans, queue rebuild, and call detection startup. It is probably improving first-record latency, but it can hurt perceived launch speed and responsiveness if the vault or recordings directory grows.

```492:522:Parley/Recording/RecordingController.swift
func launchWarmup() {
    guard !didWarmup else { return }
    didWarmup = true
    // ...
    VaultMigration.runIfNeeded(vault: settings.vaultURL)
    SystemAudioCapture.cleanupLeakedAggregates()
    ModelManager.recoverFromCrashedLoadIfNeeded()
    gatherRecoveries()
    recoverOrphanedPartials()
    vault.refresh()
    store.refresh()
    wireBackgroundQueues()
    offlineService.enqueuePendingFromDisk()
    summaryService.enqueuePendingFromDisk()
    preloadModel()
    scheduleIdleUnload()
    startCallDetection()
    Task {
        let micGranted = await PermissionManager.requestMicrophone()
        // ...
    }
}
```

This area likely wants “fast shell launch, deferred heavy hydration” rather than “fully initialize everything immediately.”

5. `VaultDirectory.refresh()` and `TranscriptStore.refresh()` are main-actor disk scans/parses. They’re fine at small scale, but they are structurally vulnerable as the vault grows because they do directory walking, file reads, parsing, sorting, and republishing from `@MainActor`.

```106:155:Parley/Recording/VaultDirectory.swift
func refresh() {
    migrateContactsFileIfNeeded()
    destinations = loadDestinations()
    let contactsText = (try? String(contentsOf: settings.contactsURL, encoding: .utf8)) ?? ""
    let contacts = Self.parseContacts(contactsText)
    // ...
    people = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    // ...
    self.contacts = contacts
    fileCustomers = loadFileCustomers(contacts: contacts)
}
```

```37:50:Parley/Recording/TranscriptStore.swift
func refresh() {
    AppPaths.ensureVaultFolders()
    var found: [TranscriptItem] = []
    found.append(contentsOf: scan(AppPaths.unprocessedURL, processed: false))
    found.append(contentsOf: scan(AppPaths.processedURL, processed: true))
    found.sort {
        $0.meta.date != $1.meta.date
            ? $0.meta.date > $1.meta.date
            : $0.url.lastPathComponent > $1.url.lastPathComponent
    }
    if found != items { items = found }
}
```

These are good candidates for background snapshot building with a single main-actor publish at the end.

6. `PeopleView` rebuilds the whole joined people model repeatedly from raw contacts and voiceprints. `allPeople`, `filteredPeople`, `selectedPerson`, delete helpers, and the toolbar count all recompute from `PeopleJoin.build(...)`, which itself filters/sorts collections. If the contacts/voiceprint store gets large, this screen will scale poorly.

```28:45:Parley/UI/PeopleView.swift
private var allPeople: [Person] {
    PeopleJoin.build(contacts: vault.contacts, voiceprints: voiceprintStore.voiceprints)
}

private var filteredPeople: [Person] {
    let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return allPeople }
    return allPeople.filter { person in
        person.displayName.lowercased().contains(q)
        || (person.contact?.company?.lowercased().contains(q) ?? false)
        || (person.contact?.title?.lowercased().contains(q) ?? false)
    }
}
```

7. The live transcript path is fairly careful already, but there are still some avoidable per-update costs. `updateLiveWordCount(from:)` rebuilds an ID set and re-walks the whole merged segment array on every publish, and `LiveTranscriptView` animates auto-scroll on both count changes and last-text changes. That may be okay at current scale, but it can become noticeable during long, fast-moving transcripts.

```240:250:Parley/Recording/RecordingController.swift
private func updateLiveWordCount(from merged: [Segment]) {
    var byID = wordCountBySegmentID
    let ids = Set(merged.map(\.id))
    for id in byID.keys where !ids.contains(id) {
        byID.removeValue(forKey: id)
    }
    for seg in merged {
        byID[seg.id] = Self.wordCount(in: seg.text)
    }
    wordCountBySegmentID = byID
    live.liveWordCount = byID.values.reduce(0, +)
}
```

8. `RecordingsStore.refresh()` computes recursive folder sizes eagerly for every session. That is a classic “settings screen feels heavy” issue once users accumulate many recordings.

```25:45:Parley/Recording/RecordingsStore.swift
func refresh() {
    let fm = FileManager.default
    let root = AppPaths.recordingsDirectory
    guard let entries = try? fm.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]) else {
        sessions = []
        return
    }
    sessions = entries.compactMap { url -> RecordingFolder? in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        let manifest = SessionStore.read(url)
        let title = (manifest?.title.isEmpty == false) ? manifest!.title : url.lastPathComponent
        let date = manifest?.startedAt
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date.distantPast
        return RecordingFolder(url: url, title: title, date: date,
                               sizeBytes: MeetingFiles.size(of: url),
                               isActive: manifest?.status == .active)
    }
    .sorted { $0.date > $1.date }
}
```

## What Already Looks Good

A few parts are already performance-aware:

- `LiveSegmentStore.apply(...)` tries hard to avoid replacing the whole transcript array unnecessarily.
- `OfflineProcessingService` and `JobProgressRelay` throttle progress updates instead of blasting the UI.
- The live transcript only renders a tail window by default, which is the right shape for long sessions.

So the app does not look fundamentally inefficient; the main weakness is that several UI/data surfaces still do disk and derivation work synchronously on the main actor.

## Highest-Value Optimization Plan

If the goal is raw speed, I’d prioritize future work in this order:

1. Move `HistoryView` to a precomputed view-model layer for row stage/status/bar data.
2. Remove synchronous file reads from search and preview selection paths.
3. Push vault/transcript scans off the main actor and publish snapshots back.
4. Split launch warmup into critical vs deferrable work.
5. Cache or memoize `PeopleView`’s joined model.
6. Make storage/session byte-size calculation lazy or incremental.

## Confidence And Next Evidence

These are code-review findings, not Instruments-backed measurements yet. The strongest likely wins are the `HistoryView` recomputation path, synchronous content search, synchronous preview loading, and main-actor startup refreshes.

If you want, the next step can be a proper profiling plan: I can give you a very targeted checklist for measuring launch time, history tab latency, search latency, and live transcript CPU in Instruments before we touch any code.
