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
}
