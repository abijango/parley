import Foundation
import AVFoundation

/// Durable, on-disk state for one recording session — the foundation of crash
/// recovery and resume.
///
/// Written to `<session>/session.json` at record start, refreshed on a periodic
/// heartbeat (which also captures the latest user-editable metadata), and marked
/// `.finalized` on a clean stop. At launch, any manifest still `.active` means
/// the app died mid-recording: the session — and its crash-safe `.caf` audio —
/// can be recovered or resumed.
struct SessionManifest: Codable, Equatable {
    enum Status: String, Codable { case active, finalized }

    /// Offline-processing lifecycle for the *background* batch pass (ASR re-pass +
    /// diarization + speaker ID + compaction), run by `OfflineProcessingService`
    /// AFTER a clean stop. Orthogonal to `status`: a finalized recording normally
    /// becomes `.pending`, runs to `.done`, or `.failed` after repeated attempts.
    /// `nil` = legacy manifest / never queued (e.g. a non-speaker engine).
    enum OfflineStatus: String, Codable { case pending, running, done, failed }

    /// Background Claude-summary lifecycle, mirroring `OfflineStatus`, so a queued-but-
    /// not-yet-run summary survives a quit and is re-collected at launch (under the
    /// bulk-confirm policy, not a silent burst). `paused` = a usage-limit trip.
    enum SummaryStatus: String, Codable { case queued, running, paused, done, failed }

    var id: String                 // = session folder name (stable, sortable timestamp)
    var title: String
    var attendees: String          // comma-joined, as the controller stores it
    var filing: String             // vault-relative destination path
    var model: String
    var computeMode: String
    var startedAt: Date
    var lastHeartbeat: Date
    var status: Status
    var startedByDetection: Bool
    var callBundleID: String?
    var callDisplayName: String?
    var manualNotes: String
    /// Audio track files in this session, in capture order (resume appends one).
    var audioTracks: [String]
    // Meeting-metadata discovery (Accessibility). Optional so manifests written
    // before this feature still decode.
    /// Where the title came from: "callWindow" | "calendar:teams" |
    /// "calendar:outlook" | "zoomHome" | "user" | nil (default "(App) call").
    var titleSource: String?
    /// Roster discovered via AX — suggestions only; `accepted` marks the ones
    /// the user moved into `attendees`.
    var suggestedAttendees: [SuggestedAttendee]?
    // Offline-processing queue state (all optional so older manifests still decode).
    /// Where this session sits in the background offline pipeline (nil ⇒ never queued).
    var offlineStatus: OfflineStatus?
    /// How many times the offline pass has been attempted (for the retry cap).
    var offlineAttempts: Int?
    /// Absolute path of the transcript the offline pass should (guardedly) rewrite.
    var transcriptPath: String?
    /// True when finishing the pass should open the speaker-review sheet (the History
    /// "Detect speakers" flow); false/nil for the silent automatic post-stop pass.
    var presentReviewWhenDone: Bool?
    /// Background Claude-summary state for this session's transcript (nil ⇒ never queued).
    var summaryStatus: SummaryStatus?
}

/// One person discovered in the meeting roster, with the join timestamp
/// (first time the AX poller saw them).
struct SuggestedAttendee: Codable, Equatable, Identifiable {
    var name: String
    var role: String?          // "Organizer" / "Host" / …
    var firstSeen: Date
    var accepted = false
    var dismissed = false
    var id: String { name.lowercased() }
}

/// A crashed session offered for recovery in the launch Recovery sheet.
struct RecoverableSession: Identifiable, Equatable {
    let dir: URL
    let manifest: SessionManifest
    let durationSeconds: Double
    var id: String { manifest.id }
}

/// Reads/writes session manifests and finds crashed sessions at launch.
enum SessionStore {
    /// Duration (seconds) of an audio file from its frame count, or 0 if unreadable.
    static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func manifestURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("session.json")
    }

    static func write(_ manifest: SessionManifest, to sessionDir: URL) {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(manifest).write(to: manifestURL(in: sessionDir), options: .atomic)
        } catch {
            AppLog.log("session.json write failed: \(error.localizedDescription)", category: "record")
        }
    }

    static func read(_ sessionDir: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: manifestURL(in: sessionDir)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionManifest.self, from: data)
    }

    /// All session dirs whose manifest is still `.active` — i.e. the app crashed
    /// mid-recording — oldest first.
    static func crashedSessions() -> [(dir: URL, manifest: SessionManifest)] {
        let recordings = AppPaths.recordingsDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil) else { return [] }
        return dirs
            .compactMap { dir -> (URL, SessionManifest)? in
                guard let m = read(dir), m.status == .active else { return nil }
                return (dir, m)
            }
            .sorted { $0.1.startedAt < $1.1.startedAt }
            .map { (dir: $0.0, manifest: $0.1) }
    }

    /// Finalized sessions whose offline pass hasn't finished — `.pending` (never run)
    /// or `.running` (crashed mid-pass → safe to re-run, since the pass is idempotent
    /// and the rewrite is coverage-guarded). Oldest first, so the queue drains FIFO.
    static func pendingOfflineSessions() -> [(dir: URL, manifest: SessionManifest)] {
        let recordings = AppPaths.recordingsDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil) else { return [] }
        return dirs
            .compactMap { dir -> (URL, SessionManifest)? in
                guard let m = read(dir),
                      m.offlineStatus == .pending || m.offlineStatus == .running else { return nil }
                return (dir, m)
            }
            .sorted { $0.1.startedAt < $1.1.startedAt }
            .map { (dir: $0.0, manifest: $0.1) }
    }

    /// Atomically stamp the offline-pass state onto a session's manifest on disk
    /// (read-modify-write). Used by the offline queue to persist progress so a crash
    /// re-discovers in-flight work. Optional params are written only when supplied.
    static func setOfflineStatus(_ status: SessionManifest.OfflineStatus,
                                 attempts: Int? = nil,
                                 transcriptPath: String? = nil,
                                 presentReviewWhenDone: Bool? = nil,
                                 in dir: URL) {
        guard var m = read(dir) else { return }
        m.offlineStatus = status
        if let attempts { m.offlineAttempts = attempts }
        if let transcriptPath { m.transcriptPath = transcriptPath }
        if let presentReviewWhenDone { m.presentReviewWhenDone = presentReviewWhenDone }
        write(m, to: dir)
    }

    /// Atomically stamp the summary state onto a session's manifest (read-modify-write),
    /// so a queued-but-unrun summary survives a quit.
    static func setSummaryStatus(_ status: SessionManifest.SummaryStatus?, in dir: URL) {
        guard var m = read(dir) else { return }
        m.summaryStatus = status
        write(m, to: dir)
    }

    /// Finalized sessions whose summary hasn't completed — `.queued`/`.paused`/`.running`
    /// (a crash mid-run). Used at launch to re-collect pending summaries (then routed
    /// through the bulk-confirm policy). Oldest first.
    static func pendingSummarySessions() -> [(dir: URL, manifest: SessionManifest)] {
        let recordings = AppPaths.recordingsDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil) else { return [] }
        return dirs
            .compactMap { dir -> (URL, SessionManifest)? in
                guard let m = read(dir),
                      m.summaryStatus == .queued || m.summaryStatus == .paused || m.summaryStatus == .running
                else { return nil }
                return (dir, m)
            }
            .sorted { $0.1.startedAt < $1.1.startedAt }
            .map { (dir: $0.0, manifest: $0.1) }
    }
}
