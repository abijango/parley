import SwiftUI

/// Settings tab -- Speakers.
///
/// Voiceprint management (rebuild, delete, play, export/import) has moved to the
/// People tab. This stub redirects users there for one release.
///
/// The People tab exposes:
///   - Per-person: delete voiceprint, rebuild WhisperKit from clip, re-enroll
///     FluidAudio from clip, play retained clip.
///   - Store-wide: export/import (backup & transfer) via the Backup button in
///     the People list toolbar.
struct SpeakersSettingsView: View {
    @ObservedObject var store: VoiceprintStore
    var diarizationThreshold: Double = 0.6

    var body: some View {
        Form {
            Section("Speakers have moved") {
                Text("Speaker voiceprint management is now in the People tab. Select a person to rebuild, delete, or play their voiceprint. Use the Backup button in the People list to export or import voiceprints for backup and transfer.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(Theme.Palette.accent)
                    Text("\(store.voiceprints.count) voiceprint\(store.voiceprints.count == 1 ? "" : "s") stored.")
                        .font(Theme.Typography.caption)
                }
                .padding(.vertical, Theme.Spacing.xSmall)
            }
        }
        .formStyle(.grouped)
    }
}
