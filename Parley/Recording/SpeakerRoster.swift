import Foundation
import Combine

/// One diarized person, as the speaker strip shows them (live call or History).
struct StripSpeaker: Identifiable, Equatable {
    let id: String              // canonical diarization speakerId
    var name: String?
    var talkSeconds: TimeInterval
    var recentLines: [String]   // newest last, at most `SpeakerRoster.recentLineCount`
    var firstSeen: TimeInterval
    /// Voiceprint or unique-attendee suggestion — offered, never auto-committed.
    var guessedName: String? = nil
    /// A voice clip can be played for this speaker.
    var hasClip: Bool = false

    var displayName: String { name ?? "Speaker \(id)" }
    var isNamed: Bool { name?.isEmpty == false }
}

/// Speakers plus the strip↔transcript interaction state. Separate from
/// `LiveSegmentStore` so the strip never observes `[Segment]` in a SwiftUI body.
@MainActor
final class SpeakerRoster: ObservableObject {
    static let recentLineCount = 3

    /// Unnamed first, then named; each group in order of first appearance.
    @Published private(set) var speakers: [StripSpeaker] = []
    /// Speaker whose naming menu is open: their rows are tinted, the transcript stops
    /// following, and the strip stops reordering, so nothing moves under the menu.
    @Published var focusedSpeakerId: String? {
        didSet {
            guard focusedSpeakerId == nil, let held else { return }
            self.held = nil
            if held != speakers { speakers = held }
        }
    }
    /// Latest list while a menu is open, published when it closes.
    private var held: [StripSpeaker]?
    /// Set by a row's speaker label; the strip opens that chip's menu and clears it.
    @Published var menuRequest: String?
    /// Live only: whether the engine holds a clip for a speaker yet.
    var clipAvailable: ((String) -> Bool)?

    func update(from segments: [Segment]) {
        var next = Self.speakers(from: segments)
        if let clipAvailable {
            for i in next.indices { next[i].hasClip = clipAvailable(next[i].id) }
        }
        set(next)
    }

    /// Replace the list wholesale (History, from the persisted speaker cache).
    func set(_ next: [StripSpeaker]) {
        if focusedSpeakerId != nil {
            held = next
        } else if next != speakers {
            speakers = next
        }
    }

    func reset() {
        held = nil
        focusedSpeakerId = nil
        if !speakers.isEmpty { speakers = [] }
        menuRequest = nil
    }

    nonisolated static func speakers(from segments: [Segment]) -> [StripSpeaker] {
        var byId: [String: StripSpeaker] = [:]
        var order: [String] = []
        for s in segments {
            guard let id = s.speakerId else { continue }
            let line = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if byId[id] == nil {
                order.append(id)
                byId[id] = StripSpeaker(id: id, name: nil, talkSeconds: 0, recentLines: [], firstSeen: s.start)
            }
            byId[id]!.talkSeconds += max(0, s.end - s.start)
            if let n = s.speakerName, !n.isEmpty { byId[id]!.name = n }
            if !line.isEmpty {
                byId[id]!.recentLines.append(line)
                if byId[id]!.recentLines.count > recentLineCount { byId[id]!.recentLines.removeFirst() }
            }
        }
        return ordered(order.compactMap { byId[$0] })
    }

    /// History: one chip per cached speaker; clips play from the call's `mixed.caf`.
    nonisolated static func speakers(from cache: SpeakerCache, clipsPlayable: Bool) -> [StripSpeaker] {
        ordered(cache.speakers.map { s in
            StripSpeaker(
                id: s.id,
                name: s.resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                talkSeconds: s.talkSeconds,
                recentLines: s.firstLine.isEmpty ? [] : [s.firstLine],
                firstSeen: s.sampleStart,
                guessedName: s.guessedName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                hasClip: clipsPlayable && s.sampleEnd > s.sampleStart)
        })
    }

    private nonisolated static func ordered(_ all: [StripSpeaker]) -> [StripSpeaker] {
        all.filter { !$0.isNamed } + all.filter(\.isNamed)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
