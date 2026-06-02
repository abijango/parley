import Foundation
import Combine

/// One transcript in the app-owned vault folder, surfaced to the History tab.
struct TranscriptItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    var meta: TranscriptMeta
    var isProcessed: Bool

    static func == (lhs: TranscriptItem, rhs: TranscriptItem) -> Bool {
        lhs.url == rhs.url
            && lhs.isProcessed == rhs.isProcessed
            && lhs.meta.status == rhs.meta.status
            && lhs.meta.note == rhs.meta.note
            && lhs.meta.title == rhs.meta.title
    }
}

/// Scans the app-owned `Unprocessed/` and `Processed/` folders, parses each
/// transcript's frontmatter, and publishes a newest-first list for the History tab.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []

    /// Rescans both folders and republishes `items`.
    func refresh() {
        AppPaths.ensureVaultFolders()
        var found: [TranscriptItem] = []
        found.append(contentsOf: scan(AppPaths.unprocessedURL, processed: false))
        found.append(contentsOf: scan(AppPaths.processedURL, processed: true))
        found.sort { $0.meta.date > $1.meta.date }
        items = found
    }

    /// Moves a transcript into `Processed/` and stamps its frontmatter.
    @discardableResult
    func moveToProcessed(_ item: TranscriptItem, notePath: String) -> URL {
        let fm = FileManager.default
        let dest = uniqueDestination(for: item.url.lastPathComponent, in: AppPaths.processedURL)
        do {
            AppPaths.ensureVaultFolders()
            if item.url != dest {
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: item.url, to: dest)
            }
            TranscriptWriter.updateFrontmatter(at: dest) { meta in
                meta.status = "processed"
                meta.note = notePath
            }
        } catch {
            AppLog.log("moveToProcessed failed: \(error.localizedDescription)", category: "history")
        }
        refresh()
        return dest
    }

    /// Writes a standalone manual note (final, no AI) into `Processed/` and returns its URL.
    @discardableResult
    func save(manualBody: String, meta: TranscriptMeta) -> URL {
        AppPaths.ensureVaultFolders()
        let folder = AppPaths.processedURL
        let filename = "\(fileStamp(meta.date)) - \(TranscriptWriter.sanitize(meta.title.isEmpty ? "Manual note" : meta.title)).md"
        let url = uniqueDestination(for: filename, in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try manualBody.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("save manual note failed: \(error.localizedDescription)", category: "history")
        }
        refresh()
        return url
    }

    // MARK: Scanning

    private func scan(_ folder: URL, processed: Bool) -> [TranscriptItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [TranscriptItem] = []
        for url in entries {
            // Skip the staging dir, hidden files, non-markdown.
            if url.lastPathComponent.hasPrefix(".") { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let meta = TranscriptWriter.parseFrontmatter(url) ?? fallbackMeta(url, processed: processed)
            result.append(TranscriptItem(url: url, meta: meta, isProcessed: processed))
        }
        return result
    }

    /// Best-effort metadata when a file has no frontmatter: title/date from the
    /// filename, status from the folder, type "recording".
    private func fallbackMeta(_ url: URL, processed: Bool) -> TranscriptMeta {
        let stem = url.deletingPathExtension().lastPathComponent
        var title = stem
        var date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        // Filenames look like "YYYY-MM-DD-HHMM - Title".
        if let dash = stem.range(of: " - ") {
            let prefix = String(stem[stem.startIndex..<dash.lowerBound])
            title = String(stem[dash.upperBound...])
            if let d = parseStampDate(prefix) { date = d }
        } else if let d = parseStampDate(String(stem.prefix(10))) {
            date = d
        }

        return TranscriptMeta(
            title: title.isEmpty ? stem : title,
            date: date, attendees: [], filing: "",
            status: processed ? "processed" : "unprocessed",
            note: nil, audio: nil, type: "recording"
        )
    }

    // MARK: Helpers

    private func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var n = 2
        repeat {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    private func parseStampDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd-HHmm", "yyyy-MM-dd-HHmmss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
