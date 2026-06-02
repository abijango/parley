import Foundation

/// Append-only journal of confirmed transcript segments for one session.
///
/// Each confirmed `Segment` is written as one JSON line the moment it's
/// confirmed (keyed on its stable `id` so it's written exactly once). This keeps
/// the crash-loss window to the tentative tail (~2 segments) instead of the
/// 15-second window of the old full-`.md` rewrite, and — unlike markdown — the
/// structured form rebuilds cleanly into `[Segment]` for both Recover and
/// Resume. The unconfirmed tail is intentionally not journaled; the crash-safe
/// `.caf` still holds the audio for a full re-transcribe if needed.
final class SegmentJournal {
    private let url: URL
    private var writtenIDs = Set<UUID>()
    private let encoder = JSONEncoder()

    /// `alreadyWritten` pre-seeds the set of segment IDs already on disk — used on
    /// resume so the prior journal isn't re-appended (no duplicates).
    init(url: URL, alreadyWritten: Set<UUID> = []) {
        self.url = url
        self.writtenIDs = alreadyWritten
    }

    /// Appends any confirmed segments not yet written. Cheap and idempotent.
    func append(confirmed: [Segment]) {
        let fresh = confirmed.filter { !writtenIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        var blob = ""
        for seg in fresh {
            guard let data = try? encoder.encode(seg),
                  let line = String(data: data, encoding: .utf8) else { continue }
            blob += line + "\n"
            writtenIDs.insert(seg.id)
        }
        guard let data = blob.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(data)
        } else {
            try? data.write(to: url, options: .atomic)   // first write creates the file
        }
    }

    /// Rebuilds the journaled segments, sorted onto the shared timeline.
    static func read(_ url: URL) -> [Segment] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text
            .split(separator: "\n")
            .compactMap { line -> Segment? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? dec.decode(Segment.self, from: data)
            }
            .sorted { $0.start < $1.start }
    }
}
