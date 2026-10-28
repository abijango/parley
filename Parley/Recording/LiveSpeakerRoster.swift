import Foundation
import Combine

/// One diarized person in the live call, as the speaker strip shows them.
struct LiveSpeaker: Identifiable, Equatable {
    let id: String              // canonical diarization speakerId
    var name: String?
    var talkSeconds: TimeInterval
    var recentLines: [String]   // newest last, at most `LiveSpeakerRoster.recentLineCount`
    var firstSeen: TimeInterval

    var displayName: String { name ?? "Speaker \(id)" }
    var isNamed: Bool { name?.isEmpty == false }
}

/// Live speakers plus the strip↔table interaction state. Separate from
/// `LiveSegmentStore` so the strip never observes `[Segment]` in a SwiftUI body.
@MainActor
final class LiveSpeakerRoster: ObservableObject {
    static let recentLineCount = 3

    /// Unnamed first, then named; each group in order of first appearance.
    @Published private(set) var speakers: [LiveSpeaker] = []
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
    private var held: [LiveSpeaker]?
    /// Set by a row's speaker label; the strip opens that chip's menu and clears it.
    @Published var menuRequest: String?

    func update(from segments: [Segment]) {
        let next = Self.speakers(from: segments)
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

    nonisolated static func speakers(from segments: [Segment]) -> [LiveSpeaker] {
        var byId: [String: LiveSpeaker] = [:]
        var order: [String] = []
        for s in segments {
            guard let id = s.speakerId else { continue }
            let line = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if byId[id] == nil {
                order.append(id)
                byId[id] = LiveSpeaker(id: id, name: nil, talkSeconds: 0, recentLines: [], firstSeen: s.start)
            }
            byId[id]!.talkSeconds += max(0, s.end - s.start)
            if let n = s.speakerName, !n.isEmpty { byId[id]!.name = n }
            if !line.isEmpty {
                byId[id]!.recentLines.append(line)
                if byId[id]!.recentLines.count > recentLineCount { byId[id]!.recentLines.removeFirst() }
            }
        }
        let all = order.compactMap { byId[$0] }
        return all.filter { !$0.isNamed } + all.filter(\.isNamed)
    }
}
