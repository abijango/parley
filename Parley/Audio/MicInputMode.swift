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

/// Fixed boost applied in `.room` mode (multiply + hard clamp).
enum MicInputGain {
    /// +6 dB — enough to lift a distant talker without instantly hard-clipping
    /// normal close-mic speech.
    static let roomMultiplier: Float = 2.0

    /// Boosts `buffer` in place. Returns `true` when samples were modified.
    @discardableResult
    static func apply(to buffer: AVAudioPCMBuffer, mode: MicInputMode) -> Bool {
        guard mode == .room, buffer.frameLength > 0 else { return false }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let gain = roomMultiplier

        if let channelData = buffer.floatChannelData {
            for ch in 0..<channels {
                let ptr = channelData[ch]
                for i in 0..<frames {
                    ptr[i] = min(1.0, max(-1.0, ptr[i] * gain))
                }
            }
            return true
        }

        // Some input devices expose Int16 tap buffers; floatChannelData is nil there.
        if let channelData = buffer.int16ChannelData {
            let lo = Float(Int16.min)
            let hi = Float(Int16.max)
            for ch in 0..<channels {
                let ptr = channelData[ch]
                for i in 0..<frames {
                    let scaled = Float(ptr[i]) * gain
                    ptr[i] = Int16(min(hi, max(lo, scaled)))
                }
            }
            return true
        }

        return false
    }

    static func apply(_ samples: [Float], mode: MicInputMode) -> [Float] {
        guard mode == .room else { return samples }
        let gain = roomMultiplier
        return samples.map { min(1.0, max(-1.0, $0 * gain)) }
    }
}
