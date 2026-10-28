import SwiftUI

/// History's speaker strip: the same chips as the live call, backed by the meeting's
/// persisted speaker cache (`speakers.json`), with ▶ playing each voice from `mixed.caf`.
/// Naming applies at once — transcript relabel, voiceprint, attendees — and a summary
/// written before the change gets a one-click Regenerate.
struct HistorySpeakerStrip: View {
    let item: TranscriptItem
    let audioAvailable: Bool
    let onRegenerateSummary: () -> Void

    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var vault: VaultDirectory
    @StateObject private var roster = SpeakerRoster()
    /// Meetings whose speaker names changed here after their summary was written.
    @State private var renamedSinceSummary: Set<URL> = []

    private var sessionDir: URL? { MeetingFiles.sessionDir(forAudioPath: item.meta.audio) }
    private var hasUnnamed: Bool { roster.speakers.contains { !$0.isNamed } }
    private var hasSummary: Bool {
        item.summaryReadyURL != nil || item.meta.note?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if hasUnnamed {
                Text("Speakers").font(Theme.Typography.fieldLabel).foregroundStyle(.secondary)
                SpeakerStrip(
                    roster: roster,
                    people: vault.people,
                    attendees: item.meta.attendees,
                    onName: name,
                    onMerge: merge,
                    onPlay: play,
                    standalone: false,
                    nudgesArrivals: false,
                    unavailableClipHelp: "This meeting's audio is no longer available")
            } else if item.hasUnnamedSpeakers {
                StatusBanner(.warning,
                             audioAvailable
                             ? "Speakers aren't assigned yet. Detect speakers to name them."
                             : "Speakers aren't assigned and the audio is no longer available to detect them.",
                             symbol: "person.crop.circle.badge.exclamationmark")
            }
            if renamedSinceSummary.contains(item.url), hasSummary {
                StatusBanner(.info, "Speaker names changed since the summary was written.",
                             symbol: "person.2.wave.2",
                             actionLabel: "Regenerate summary") {
                    renamedSinceSummary.remove(item.url)
                    onRegenerateSummary()
                }
            }
        }
        .task(id: "\(item.url.path)#\(recording.transcriptRevision)") { reload() }
        .onDisappear { recording.stopClip() }
    }

    private func reload() {
        guard let dir = sessionDir, let cache = SpeakerCache.read(dir) else {
            roster.reset()
            return
        }
        let playable = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(cache.mixedCafName).path)
        roster.set(SpeakerRoster.speakers(from: cache, clipsPlayable: playable))
    }

    private func name(_ speakerId: String, _ name: String) {
        if hasSummary { renamedSinceSummary.insert(item.url) }
        recording.confirmSpeakerGuess(on: item.url, speakerId: speakerId, name: name)
    }

    private func merge(_ speakerId: String, into target: String) {
        if let targetName = roster.speakers.first(where: { $0.id == target })?.name {
            name(speakerId, targetName)
        } else {
            if hasSummary { renamedSinceSummary.insert(item.url) }
            recording.mergeCachedSpeaker(on: item.url, speakerId: speakerId, into: target)
        }
    }

    private func play(_ speakerId: String) -> TimeInterval {
        guard let dir = sessionDir else { return 0 }
        return recording.playCachedClip(sessionDir: dir, speakerId: speakerId)
    }
}
