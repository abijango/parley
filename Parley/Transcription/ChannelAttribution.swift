import Foundation

/// Remote-call attribution from the two capture tracks Parley archives separately
/// (`mic.caf` and `system.caf`). On a remote call the mic carries the recording owner
/// and the system track carries everyone else, so the owner's turns come from mic
/// energy and only the system track needs diarizing.
///
/// Never used for Room mode: there the single mic carries every voice in the room.
///
/// Laptop speakers bleed the far side into the mic (there is no echo cancellation),
/// so a mic frame counts as the owner only when it also clearly dominates the
/// system track at the same instant.
enum ChannelAttribution {
    static let selfSpeakerId = "me"
    static let selfLabel = SpeakerTrack.me.label

    struct Interval: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    struct Turn: Equatable, Sendable {
        let speakerId: String
        var start: TimeInterval
        var end: TimeInterval
    }

    struct Config: Sendable {
        var frameSeconds: TimeInterval = 0.05
        /// Absolute RMS floor; quiet rooms still need this much before a frame is speech.
        var absoluteFloor: Float = 0.002
        /// Speech must sit this far above the track's own noise floor (10th percentile).
        var noiseMultiple: Float = 4
        /// Ceiling on the threshold, so a track that is speech nearly end to end (a
        /// monologue) doesn't read its own speech as the noise floor.
        var maxThreshold: Float = 0.02
        /// Mic RMS must exceed the system RMS by this factor to rule out speaker bleed.
        var dominance: Float = 2
        var bridgeGap: TimeInterval = 0.4
        var minTurn: TimeInterval = 0.5
        var pad: TimeInterval = 0.1
        /// System speech needed before the call counts as remote at all.
        var minRemoteSpeech: TimeInterval = 5
        /// Remote turns shorter than this after subtracting the owner's turns are dropped.
        var minRemoteFragment: TimeInterval = 0.2
    }

    /// RMS per `frameSeconds` frame.
    static func envelope(_ samples: [Float], sampleRate: Double = 16_000,
                         frameSeconds: TimeInterval = Config().frameSeconds) -> [Float] {
        let frame = max(1, Int(sampleRate * frameSeconds))
        guard !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / frame + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + frame)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            out.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        return out
    }

    static func speechThreshold(_ envelope: [Float], config: Config = Config()) -> Float {
        guard !envelope.isEmpty else { return config.absoluteFloor }
        let sorted = envelope.sorted()
        let noise = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return max(config.absoluteFloor, min(config.maxThreshold, noise * config.noiseMultiple))
    }

    /// True when the system track has enough speech for this to be a remote call.
    /// An in-person meeting recorded in Regular mode has a near-silent system track,
    /// and splitting it would label the whole room as the owner.
    static func systemHasSpeech(_ system: [Float], config: Config = Config()) -> Bool {
        let threshold = speechThreshold(system, config: config)
        let active = system.lazy.filter { $0 > threshold }.count
        return Double(active) * config.frameSeconds >= config.minRemoteSpeech
    }

    /// The owner's speaking turns: mic frames above the mic's speech threshold that
    /// also dominate the system track, bridged over short pauses.
    static func selfTurns(mic: [Float], system: [Float], config: Config = Config()) -> [Interval] {
        guard !mic.isEmpty else { return [] }
        let micThreshold = speechThreshold(mic, config: config)
        var raw: [Interval] = []
        var runStart: Int?
        for i in 0...mic.count {
            let active: Bool = {
                guard i < mic.count else { return false }
                let sys = i < system.count ? system[i] : 0
                return mic[i] > micThreshold && mic[i] > sys * config.dominance
            }()
            if active, runStart == nil { runStart = i }
            if !active, let s = runStart {
                raw.append(Interval(start: Double(s) * config.frameSeconds,
                                    end: Double(i) * config.frameSeconds))
                runStart = nil
            }
        }
        var bridged: [Interval] = []
        for r in raw {
            if let last = bridged.last, r.start - last.end <= config.bridgeGap {
                bridged[bridged.count - 1].end = r.end
            } else {
                bridged.append(r)
            }
        }
        let total = Double(mic.count) * config.frameSeconds
        return bridged
            .filter { $0.duration >= config.minTurn }
            .map { Interval(start: max(0, $0.start - config.pad), end: min(total, $0.end + config.pad)) }
    }

    /// Owner turns plus remote diarization turns with the owner's spans cut out, sorted
    /// and non-overlapping, so midpoint attribution never has to pick between the two.
    static func merge(selfTurns: [Interval], remote: [Turn], config: Config = Config()) -> [Turn] {
        let mine = selfTurns.sorted { $0.start < $1.start }
        var out: [Turn] = mine.map { Turn(speakerId: selfSpeakerId, start: $0.start, end: $0.end) }
        for turn in remote {
            var pieces = [Interval(start: turn.start, end: turn.end)]
            for m in mine where m.end > turn.start && m.start < turn.end {
                pieces = pieces.flatMap { p -> [Interval] in
                    guard m.end > p.start, m.start < p.end else { return [p] }
                    var kept: [Interval] = []
                    if m.start > p.start { kept.append(Interval(start: p.start, end: m.start)) }
                    if m.end < p.end { kept.append(Interval(start: m.end, end: p.end)) }
                    return kept
                }
            }
            out += pieces
                .filter { $0.duration >= config.minRemoteFragment }
                .map { Turn(speakerId: turn.speakerId, start: $0.start, end: $0.end) }
        }
        return out.sorted { $0.start < $1.start }
    }
}
