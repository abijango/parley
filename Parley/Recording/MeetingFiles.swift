import Foundation

/// The on-disk artifacts that make up one "meeting": the transcript itself, its recorded
/// audio session, the filed summary note, and any pending staged summary.
///
/// This is never persisted — it's a resolved view of links that already live in the
/// transcript's frontmatter (`audio:` / `note:`). The History tab surfaces it as the
/// visible "meeting record" and uses it to drive cascade-aware deletes.
struct MeetingLinks {
    let transcript: URL
    /// The recording **session folder** (parent of the `.caf`), validated to live under the
    /// app's `Recordings/` root. nil when there's no audio link, it's external, or it's gone.
    let audioSession: URL?
    /// The filed summary note, if `note:` is set and the file still exists.
    let note: URL?
    /// A summary staged for review (`.staging/<base>.md`), if present.
    let staging: URL?
    /// Recursive byte size of the audio session folder (0 when there's no audio).
    let audioBytes: Int64

    var hasAudio: Bool { audioSession != nil }
    var hasNote: Bool { note != nil }
}

/// Pure, nonisolated filesystem helpers shared by `TranscriptStore`, `RecordingsStore`, and
/// `SummaryService` for resolving and safely operating on a meeting's linked files.
enum MeetingFiles {
    /// Resolves the linked artifacts for a transcript's metadata. `staging` is the staged-summary
    /// URL if one exists (the caller already knows this from the scan), else nil.
    static func links(transcript: URL, meta: TranscriptMeta, staging: URL?) -> MeetingLinks {
        let fm = FileManager.default
        let session = sessionDir(forAudioPath: meta.audio)
        let note: URL? = {
            guard let n = meta.note, !n.isEmpty else { return nil }
            let u = URL(fileURLWithPath: n)
            return fm.fileExists(atPath: u.path) ? u : nil
        }()
        let bytes = session.map { size(of: $0) } ?? 0
        return MeetingLinks(transcript: transcript, audioSession: session,
                            note: note, staging: staging, audioBytes: bytes)
    }

    /// The recording session folder for an `audio:` path — but **only** when it resolves under
    /// the app's `Recordings/` root and still exists. The audio path points at e.g.
    /// `<Recordings>/<session>/mic.caf`; the session dir is its parent. This guard means a
    /// cascade delete can never escape app-owned audio, even with a hand-edited frontmatter path.
    static func sessionDir(forAudioPath audio: String?) -> URL? {
        guard let audio, !audio.isEmpty else { return nil }
        let audioURL = URL(fileURLWithPath: audio)
        let sessionDir = audioURL.deletingLastPathComponent()
        let recordingsRoot = AppPaths.recordingsDirectory.standardizedFileURL.path + "/"
        guard sessionDir.standardizedFileURL.path.hasPrefix(recordingsRoot) else { return nil }
        return FileManager.default.fileExists(atPath: sessionDir.path) ? sessionDir : nil
    }

    /// Recursively sums the byte size of a folder, or returns a single file's size.
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let s = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(s) }
        }
        return total
    }

    /// Moves a file/folder to the macOS Trash (recoverable). Returns true on success; logs and
    /// returns false on failure rather than throwing, so callers can carry on with a bulk op.
    @discardableResult
    static func trash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            AppLog.log("Trash failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "history")
            return false
        }
    }

    /// All audio segment files for a track base name, in capture order
    /// (`mic.caf`, `mic.2.caf`, …). Used by offline multi-leg concat after a mid-call resume.
    static func audioSegmentURLs(in dir: URL, base: String) -> [URL] {
        var urls: [URL] = []
        let first = dir.appendingPathComponent("\(base).caf")
        if FileManager.default.fileExists(atPath: first.path) { urls.append(first) }
        var idx = 2
        while case let u = dir.appendingPathComponent("\(base).\(idx).caf"),
              FileManager.default.fileExists(atPath: u.path) {
            urls.append(u); idx += 1
        }
        return urls
    }
}
