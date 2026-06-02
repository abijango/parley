import Foundation
import AVFoundation

/// Writes raw captured audio to a file (for archival, like the vault's
/// `Raw Transcripts/` mp3s). One archiver per track. Writes in the source
/// format to preserve quality — Whisper gets the resampled copy separately.
final class AudioArchiver {
    private let file: AVAudioFile

    init(url: URL, format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Caller passes a .caf or .wav URL; AVAudioFile infers from settings.
        self.file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// Appends a buffer. Called from the capture path; swallows write errors so
    /// a transient archive failure never kills the live transcription.
    func append(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
        } catch {
            // Non-fatal: archival is best-effort.
        }
    }
}
