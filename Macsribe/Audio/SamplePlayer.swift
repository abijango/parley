import Foundation
import AVFoundation

/// Plays a short slice of a recording's archived audio so the user can recognise a
/// speaker before naming them. Plays the mic and system `.caf` tracks together
/// (≈ what was diarized) from a start time for a bounded duration.
@MainActor
final class SamplePlayer {
    private var players: [AVAudioPlayer] = []
    private var stopTimer: Timer?

    /// Play `files` simultaneously from `start` seconds for `(end - start)` seconds.
    func play(files: [URL], start: TimeInterval, end: TimeInterval) {
        stop()
        let duration = max(0.5, end - start)
        for url in files {
            guard FileManager.default.fileExists(atPath: url.path),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            player.currentTime = min(max(0, start), max(0, player.duration - 0.05))
            player.play()
            players.append(player)
        }
        guard !players.isEmpty else { return }
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        stopTimer?.invalidate(); stopTimer = nil
        for p in players { p.stop() }
        players.removeAll()
    }

    var isPlaying: Bool { players.contains { $0.isPlaying } }
}
