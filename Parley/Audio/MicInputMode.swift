import Foundation
import AVFoundation

/// How the local microphone is scaled before archiving and live ASR.
enum MicInputMode: String, CaseIterable, Identifiable {
    case regular
    case room

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: return "Regular"
        case .room: return "Room"
        }
    }
}

/// Fixed boost applied in `.room` mode (multiply + hard clamp at ±1.0).
enum MicInputGain {
    static let roomMultiplier: Float = 2.0

    static func apply(to buffer: AVAudioPCMBuffer, mode: MicInputMode) {
        guard mode == .room else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let gain = roomMultiplier
        for ch in 0..<channels {
            let ptr = channelData[ch]
            for i in 0..<frames {
                ptr[i] = min(1.0, max(-1.0, ptr[i] * gain))
            }
        }
    }

    static func apply(_ samples: [Float], mode: MicInputMode) -> [Float] {
        guard mode == .room else { return samples }
        let gain = roomMultiplier
        return samples.map { min(1.0, max(-1.0, $0 * gain)) }
    }
}
