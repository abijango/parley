import SwiftUI
import AppKit

/// Settings tab to manage saved voiceprints: list / rename / delete, and
/// export / import for backup or transfer (plain JSON, or passphrase-encrypted).
struct SpeakersSettingsView: View {
    @ObservedObject var store: VoiceprintStore
    /// In-session clustering threshold, reused to embed retained clips on re-enrollment.
    var diarizationThreshold: Double = 0.6

    @State private var exportPassphrase = ""
    @State private var importPassphrase = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var status: String?
    @State private var player = SamplePlayer()
    @State private var reenrolling = false
    @State private var rebuilding = false

    var body: some View {
        Form {
            Section("Saved speakers") {
                Text("Voiceprints used to recognise people across calls. Stored encrypted on this Mac (key in the Keychain).")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.voiceprints.isEmpty {
                    Text("No saved speakers yet. Name a speaker after a FluidAudio recording to remember their voice.")
                        .font(Theme.Typography.secondary).foregroundStyle(.secondary)
                        .padding(.vertical, Theme.Spacing.small)
                } else {
                    ForEach(store.voiceprints) { vp in
                        row(vp)
                    }
                }
            }

            if !store.voiceprints.isEmpty {
                reEnrollSection
            }

            Section("Backup & transfer") {
                Text("Export to a file you can back up or move to another Mac. Add a passphrase to encrypt the export; leave it empty for plain (inspectable) JSON.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Export passphrase (optional)", text: $exportPassphrase).frame(width: 230)
                    Button("Export…") { exportStore() }.disabled(store.voiceprints.isEmpty)
                }
                HStack {
                    SecureField("Import passphrase (if encrypted)", text: $importPassphrase).frame(width: 230)
                    Button("Import…") { importStore() }
                }
                if let status {
                    Text(status)
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { player.stop() }
        .sheet(isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("Rename speaker").font(Theme.Typography.sheetTitle)
                TextField("Name", text: $renameText).frame(width: 240)
                    .onSubmit(commitRename)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingID = nil }
                        .glassButton()
                    Button("Save", action: commitRename)
                        .glassProminentButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(Theme.Spacing.large).frame(width: 300)
        }
    }

    /// Regenerate voiceprint vectors from retained clips — the recovery path when a
    /// FluidAudio upgrade changes the embedding model (constraint #1).
    private var reEnrollSection: some View {
        // Only FluidAudio (wespeaker) prints can be regenerated here: re-embedding
        // runs FluidAudio's extractor, so the count, the button label, and the
        // action must all exclude WhisperKit/SpeakerKit (pyannote) prints.
        let clipBacked = store.voiceprints.filter {
            $0.audioSample != nil && $0.embeddingModel != VoiceprintStore.speakerKitEmbeddingModel
        }.count
        let stale = store.staleVoiceprints.count
        // People who have a retained clip but NO pyannote (WhisperKit) print — these
        // can be rebuilt for WhisperKit from the clip (e.g. prints lost to the old
        // re-enroll bug).
        let missingPyannote = store.clipSourcesMissing(model: VoiceprintStore.speakerKitEmbeddingModel).count
        return Section("Re-enrollment") {
            Text("If a FluidAudio update changes its embedding model, FluidAudio voiceprints stop matching. Regenerate their vectors from the retained clips — no re-recording needed. WhisperKit/SpeakerKit prints are left untouched (they can't be regenerated this way).")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if stale > 0 {
                Label("\(stale) voiceprint\(stale == 1 ? "" : "s") use an outdated model and won't match until re-enrolled.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Severity.warning.color)
            }
            HStack(spacing: Theme.Spacing.small) {
                if reenrolling { ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center) }
                Button(stale > 0 ? "Re-enroll outdated (\(stale))" : "Regenerate from clips (\(clipBacked))") {
                    reEnrollFromClips(staleOnly: stale > 0)
                }
                .disabled(reenrolling || clipBacked == 0)
                if clipBacked == 0 {
                    Text("No retained clips yet.")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                }
            }
            if missingPyannote > 0 {
                Divider()
                Text("Rebuild WhisperKit (SpeakerKit) voiceprints from retained clips for people who only have a FluidAudio print — e.g. prints lost to an earlier re-enroll. Leaves existing prints untouched.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.small) {
                    if rebuilding { ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center) }
                    Button("Rebuild WhisperKit voiceprints (\(missingPyannote))") {
                        rebuildPyannoteFromClips()
                    }
                    .disabled(rebuilding)
                }
            }
        }
    }

    private func reEnrollFromClips(staleOnly: Bool) {
        let candidates = (staleOnly ? store.staleVoiceprints : store.voiceprints)
            .filter { $0.audioSample != nil }
        // pyannote (WhisperKit/SpeakerKit) prints can't be regenerated here: there's
        // no SpeakerKit clip-embedding path, and re-embedding via FluidAudio would
        // re-stamp them wespeaker_v2 — destroying WhisperKit identification for those
        // people. Exclude them so this can never silently convert across engines.
        let targets = candidates.filter { $0.embeddingModel != VoiceprintStore.speakerKitEmbeddingModel }
        let skipped = candidates.count - targets.count
        guard !targets.isEmpty else {
            status = skipped > 0
                ? "Nothing to re-enroll — \(skipped) WhisperKit print(s) can't be regenerated this way."
                : "No saved clips to re-enroll from."
            return
        }
        reenrolling = true
        status = "Re-enrolling \(targets.count) speaker(s) from saved clips…"
        let threshold = Float(diarizationThreshold)
        Task {
            var done = 0, failed = 0
            for vp in targets {
                guard let samples = store.clipSamples(vp.id),
                      let embs = await FluidAudioEngine.embeddings(forClip: samples, clusterThreshold: threshold) else {
                    failed += 1; continue
                }
                store.reEnroll(vp.id, embeddings: embs); done += 1
            }
            reenrolling = false
            status = "Re-enrolled \(done) speaker(s)"
                + (failed > 0 ? "; \(failed) skipped (clip too short or low quality)" : "")
                + (skipped > 0 ? "; \(skipped) WhisperKit print(s) left untouched" : "")
                + "."
        }
    }

    /// Recovery: for each person with a retained clip but NO pyannote print, generate a
    /// pyannote (WhisperKit/SpeakerKit) print from the clip. Additive — never touches the
    /// existing FluidAudio prints. One source clip per distinct name; loads the SpeakerKit
    /// model once for the whole batch.
    private func rebuildPyannoteFromClips() {
        let targets = store.clipSourcesMissing(model: VoiceprintStore.speakerKitEmbeddingModel)
        guard !targets.isEmpty else { status = "No clips to rebuild WhisperKit voiceprints from."; return }
        rebuilding = true
        status = "Rebuilding \(targets.count) WhisperKit voiceprint(s) from saved clips…"
        Task {
            let diarizer = SpeakerKitDiarizer()
            var done = 0, failed = 0
            for vp in targets {
                guard let samples = store.clipSamples(vp.id),
                      let centroid = await diarizer.embedding(forClip: samples) else { failed += 1; continue }
                _ = store.enroll(name: vp.name, embedding: centroid,
                                 model: VoiceprintStore.speakerKitEmbeddingModel)
                done += 1
            }
            await diarizer.unload()
            rebuilding = false
            status = "Rebuilt \(done) WhisperKit voiceprint(s)"
                + (failed > 0 ? "; \(failed) skipped (clip too short or low quality)." : ".")
        }
    }

    private func row(_ vp: Voiceprint) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            // Play the retained enrolment clip to confirm this voiceprint is the
            // right person (rename/delete to reassign if it's a mismatch).
            Button { playClip(vp) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.plain)
                .disabled(vp.audioSample == nil)
                .help(vp.audioSample == nil ? "No saved clip for this voice" : "Play the saved voice clip")

            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(vp.name).font(Theme.Typography.controlLabel)
                Text("\(vp.sampleCount) sample\(vp.sampleCount == 1 ? "" : "s")"
                     + (vp.audioSample != nil ? " · clip kept" : " · no clip")
                     + " · updated \(vp.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") { renamingID = vp.id; renameText = vp.name }
            Button(role: .destructive) { store.delete(vp.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
    }

    private func playClip(_ vp: Voiceprint) {
        guard let data = vp.audioSample else {
            AppLog.log("Speakers: \(vp.name) has no saved clip to play", category: "record"); return
        }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        AppLog.log("Speakers: playing \(vp.name) clip — \(samples.count) samples (\(String(format: "%.1fs", Double(samples.count)/16000)))", category: "record")
        player.play(samples: samples)
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renamingID, !name.isEmpty { store.rename(id, to: name) }
        renamingID = nil
    }

    private func exportStore() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportPassphrase.isEmpty ? "parley-voiceprints.json" : "parley-voiceprints.enc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportData(passphrase: exportPassphrase.isEmpty ? nil : exportPassphrase)
            try data.write(to: url, options: .atomic)
            status = "Exported \(store.voiceprints.count) speaker(s)."
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importStore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let n = try store.importData(data, passphrase: importPassphrase.isEmpty ? nil : importPassphrase)
            status = "Imported \(n) speaker(s)."
        } catch {
            status = "Import failed — wrong passphrase or unreadable file."
        }
    }
}
