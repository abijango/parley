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
                                   sizeBytes: Self.folderSize(url),
                                   isActive: manifest?.status == .active)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ folder: RecordingFolder) {
        try? FileManager.default.removeItem(at: folder.url)
        AppLog.log("Deleted recording session \(folder.id) (\(ByteCountFormatter.string(fromByteCount: folder.sizeBytes, countStyle: .file)))", category: "record")
        refresh()
    }

    /// Recursively sums the byte size of a session folder.
    private static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
