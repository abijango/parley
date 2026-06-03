import Foundation

/// Smoothed audio level (0…1) for a capture source's meter. Updated on the
/// audio thread, read on the main thread — a plain `Float` is fine here (a torn
/// read just shows a slightly stale meter value; no correctness impact).
final class LevelMeter: @unchecked Sendable {
    private(set) var level: Float = 0

    /// Feed a chunk of samples; updates the smoothed level.
    func update(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let scaled = min(1, rms * 4)            // light gain so normal speech reads mid-scale
        level = level * 0.7 + scaled * 0.3       // attack/decay smoothing
    }

    func reset() { level = 0 }
}
