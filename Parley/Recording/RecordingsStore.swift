import Foundation

/// One recording session folder on disk, for the Storage manager.
struct RecordingFolder: Identifiable, Equatable {
    let url: URL
    let title: String
    let date: Date
    let sizeBytes: Int64
    /// Manifest still `.active` — either the live recording or a crashed session.
    let isActive: Bool

    var id: String { url.lastPathComponent }
}

/// Scans `~/Library/Application Support/<App>/Recordings` so the user can see and
/// manually delete raw call audio (nothing prunes it automatically yet). Deleting
/// a session removes only its audio + recovery files; vault transcripts/notes are
/// untouched (they live in the vault and only link to the audio).
@MainActor
final class RecordingsStore: ObservableObject {
    @Published private(set) var sessions: [RecordingFolder] = []

    var totalBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }

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

    func delete(_ folder: RecordingFolder) {
        MeetingFiles.trash(folder.url)
        AppLog.log("Trashed recording session \(folder.id) (\(ByteCountFormatter.string(fromByteCount: folder.sizeBytes, countStyle: .file)))", category: "record")
        refresh()
    }

    /// Delete several sessions at once (multi-select + the "older than" purge). Recoverable
    /// (macOS Trash) for consistency with History's cascade delete.
    func delete(_ folders: [RecordingFolder]) {
        guard !folders.isEmpty else { return }
        let bytes = folders.reduce(Int64(0)) { $0 + $1.sizeBytes }
        for folder in folders { MeetingFiles.trash(folder.url) }
        AppLog.log("Trashed \(folders.count) recording session(s) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))", category: "record")
        refresh()
    }

    /// Sessions started before `date` — reusable for a future auto-purge job.
    func sessions(olderThan date: Date) -> [RecordingFolder] {
        sessions.filter { $0.date < date }
    }

    /// Sessions whose folder isn't referenced by any surviving transcript's `audio:` link —
    /// i.e. raw audio you can no longer reach from History (the transcript was deleted). Pass
    /// the standardized session-dir paths still referenced (from `TranscriptStore`).
    func orphanedSessions(referencedSessionPaths: Set<String>) -> [RecordingFolder] {
        sessions.filter { !referencedSessionPaths.contains($0.url.standardizedFileURL.path) }
    }
}
