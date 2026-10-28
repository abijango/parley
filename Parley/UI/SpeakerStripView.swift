import AppKit
import SwiftUI

/// Speaker colours shared by transcript rows and strip chips.
enum SpeakerPalette {
    private static let colors: [NSColor] = [.systemGreen, .systemOrange, .systemPurple, .systemPink,
                                            .systemTeal, .systemIndigo, .systemBrown, .systemCyan]

    /// Deterministic per id (diarization ids are small integers as strings).
    static func nsColor(for id: String) -> NSColor {
        let n = Int(id) ?? id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(n) % colors.count]
    }

    static func color(for id: String) -> Color { Color(nsColor: nsColor(for: id)) }
}

/// Speakers pinned above a transcript — live during a call, and in History from the
/// persisted speaker cache. Lives outside the transcript so its menus never vanish when
/// rows update. Unnamed speakers lead, each with ▶ to hear them; opening a chip's menu
/// tints that speaker's lines and holds both the transcript and the strip still.
struct SpeakerStrip: View {
    @ObservedObject var roster: SpeakerRoster
    let people: [String]
    let attendees: [String]
    let onName: (String, String) -> Void
    let onMerge: (String, String) -> Void
    /// Plays a speaker's clip and returns its length (0 = nothing to play).
    var onPlay: ((String) -> TimeInterval)? = nil
    /// Full-width bar with its own gutters and divider (live), or bare chips (History).
    var standalone = true
    /// Ring speakers that appear mid-call. Off in History, where all arrive at once.
    var nudgesArrivals = true
    /// Tooltip for a disabled ▶.
    var unavailableClipHelp = "No clean sample of this voice yet"

    @State private var openMenuId: String?
    @State private var seen: Set<String> = []
    @State private var nudgeId: String?
    @State private var playingId: String?

    var body: some View {
        if !roster.speakers.isEmpty {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.small) {
                            ForEach(roster.speakers) { speaker in
                                SpeakerChip(
                                    speaker: speaker,
                                    isMenuOpen: menuBinding(for: speaker.id),
                                    nudging: nudgeId == speaker.id,
                                    playing: playingId == speaker.id,
                                    onPlay: onPlay == nil ? nil : { play(speaker.id) },
                                    unavailableClipHelp: unavailableClipHelp
                                ) {
                                    menu(for: speaker)
                                }
                                .id(speaker.id)
                            }
                        }
                        .padding(.horizontal, standalone ? Theme.Spacing.large : 0)
                        .padding(.vertical, standalone ? Theme.Spacing.small : Theme.Spacing.xxSmall)
                        .animation(Theme.Motion.spring, value: roster.speakers.map(\.id))
                    }
                    .onChange(of: roster.menuRequest) { _, id in
                        guard let id else { return }
                        roster.menuRequest = nil
                        // Settle the chip first; a popover anchored mid-scroll can miss it.
                        proxy.scrollTo(id, anchor: .center)
                        DispatchQueue.main.async { openMenuId = id }
                    }
                }
                if standalone { Divider() }
            }
            .onChange(of: openMenuId) { _, id in roster.focusedSpeakerId = id }
            .onChange(of: roster.speakers.map(\.id), initial: true) { _, ids in noteArrivals(ids) }
            .onDisappear { roster.focusedSpeakerId = nil }
        }
    }

    private func menuBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { openMenuId == id },
            set: { open in
                if open { openMenuId = id } else if openMenuId == id { openMenuId = nil }
            })
    }

    private func play(_ id: String) {
        guard let onPlay else { return }
        let length = onPlay(id)
        guard length > 0 else { return }
        playingId = id
        Task {
            try? await Task.sleep(for: .seconds(length))
            if playingId == id { playingId = nil }
        }
    }

    private func menu(for speaker: StripSpeaker) -> some View {
        TranscriptSpeakerNamer(
            title: speaker.isNamed ? "Rename \(speaker.displayName)" : "Who is \(speaker.displayName)?",
            draft: speaker.name ?? "",
            people: people,
            attendees: attendees,
            others: roster.speakers.filter { $0.id != speaker.id },
            suggestion: speaker.isNamed ? nil : speaker.guessedName,
            onPlay: speaker.hasClip && onPlay != nil ? { play(speaker.id) } : nil,
            onCommit: { name in
                openMenuId = nil
                onName(speaker.id, name)
            },
            onMerge: { target in
                openMenuId = nil
                onMerge(speaker.id, target)
            })
    }

    /// Briefly ring a newly detected unnamed speaker so the arrival is noticed.
    private func noteArrivals(_ ids: [String]) {
        if ids.isEmpty {
            seen = []
            return
        }
        let fresh = ids.filter { !seen.contains($0) }
        seen.formUnion(fresh)
        guard nudgesArrivals, let id = fresh.first(where: { id in
            roster.speakers.first { $0.id == id }?.isNamed == false
        }) else { return }
        withAnimation(Theme.Motion.gentle) { nudgeId = id }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if nudgeId == id { withAnimation(Theme.Motion.gentle) { nudgeId = nil } }
        }
    }
}

private struct SpeakerChip<Menu: View>: View {
    let speaker: StripSpeaker
    @Binding var isMenuOpen: Bool
    let nudging: Bool
    let playing: Bool
    let onPlay: (() -> Void)?
    var unavailableClipHelp = "No clean sample of this voice yet"
    @ViewBuilder let menu: () -> Menu

    private var color: Color { SpeakerPalette.color(for: speaker.id) }

    var body: some View {
        HStack(spacing: 0) {
            if !speaker.isNamed, let onPlay {
                Button(action: onPlay) {
                    Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(speaker.hasClip ? color : Theme.Palette.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!speaker.hasClip)
                .help(speaker.hasClip ? "Play \(speaker.displayName)'s voice" : unavailableClipHelp)
                .accessibilityLabel("Play \(speaker.displayName)'s voice")
            }
            Button { isMenuOpen.toggle() } label: {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(speaker.displayName)
                        .font(Theme.Typography.secondary.weight(speaker.isNamed ? .regular : .semibold))
                        .foregroundStyle(speaker.isNamed ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if let guess = speaker.guessedName, !speaker.isNamed {
                        Text("· \(guess)?")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    if !speaker.isNamed {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.leading, speaker.isNamed || onPlay == nil ? Theme.Spacing.small : Theme.Spacing.xxSmall)
                .padding(.trailing, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.xSmall)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.peek(speaker))
            .accessibilityLabel(speaker.isNamed ? speaker.displayName : "\(speaker.displayName), unnamed")
            .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) { menu() }
        }
        .background(
            Theme.Radius.rect(Theme.Radius.chip).fill(color.opacity(speaker.isNamed ? Theme.Opacity.tintSubtle
                                         : (isMenuOpen ? Theme.Opacity.selection : Theme.Opacity.tintFill))))
        .overlay(
            Theme.Radius.rect(Theme.Radius.chip).strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
        .overlay(
            Theme.Radius.rect(Theme.Radius.chip).strokeBorder(Theme.Palette.accent, lineWidth: 1.5).opacity(nudging ? 1 : 0))
        .scaleEffect(nudging ? 1.06 : 1)
    }

    /// Hover text: talk time and what they said recently, to tell who they are.
    private static func peek(_ speaker: StripSpeaker) -> String {
        let s = Int(speaker.talkSeconds.rounded())
        let talk = s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
        let action = speaker.isNamed ? "Click to rename" : "Click to name"
        let lines = speaker.recentLines.map { "“\($0.count > 120 ? String($0.prefix(120)) + "…" : $0)”" }
        return (["\(speaker.displayName) · \(talk) talking"] + lines + [action]).joined(separator: "\n")
    }
}
