import Foundation

/// Append-only crash-recovery transcript: writes the document header once, then
/// appends markdown lines for each newly confirmed segment (aligned with
/// `SegmentJournal` — no periodic full-file rebuild).
final class PartialTranscriptAppender {
    private let url: URL
    private var writtenIDs = Set<UUID>()
    private var headerWritten = false

    init(url: URL, alreadyWritten: Set<UUID> = [], headerExists: Bool = false) {
        self.url = url
        self.writtenIDs = alreadyWritten
        self.headerWritten = headerExists || FileManager.default.fileExists(atPath: url.path)
    }

    /// Appends markdown for confirmed segments not yet written. `header` is invoked
    /// at most once (frontmatter + human header through `## Transcript`).
    func append(confirmed: [Segment], header: () -> String) {
        let fresh = confirmed.filter { $0.confirmed && !writtenIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }

        var blob = ""
        if !headerWritten {
            blob += header()
            if !blob.hasSuffix("\n") { blob += "\n" }
            headerWritten = true
        }
        for seg in fresh {
            blob += "\n\n" + seg.markdownLine
            writtenIDs.insert(seg.id)
        }
        guard let data = blob.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}