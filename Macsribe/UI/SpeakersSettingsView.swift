import SwiftUI
import AppKit

/// Settings tab to manage saved voiceprints: list / rename / delete, and
/// export / import for backup or transfer (plain JSON, or passphrase-encrypted).
struct SpeakersSettingsView: View {
    @ObservedObject var store: VoiceprintStore

    @State private var exportPassphrase = ""
    @State private var importPassphrase = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var status: String?
    @State private var player = SamplePlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved speakers").font(.headline)
            Text("Voiceprints used to recognise people across calls. Stored encrypted on this Mac (key in the Keychain).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.voiceprints.isEmpty {
                Text("No saved speakers yet. Name a speaker after a FluidAudio recording to remember their voice.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.voiceprints) { vp in
                            row(vp)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()
            Text("Backup & transfer").font(.headline)
            Text("Export to a file you can back up or move to another Mac. Add a passphrase to encrypt the export; leave it empty for plain (inspectable) JSON.")
                .font(.caption2).foregroundStyle(.secondary)
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
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { player.stop() }
        .sheet(isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename speaker").font(.headline)
                TextField("Name", text: $renameText).frame(width: 240)
                    .onSubmit(commitRename)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingID = nil }
                    Button("Save", action: commitRename).keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding().frame(width: 300)
        }
    }

    private func row(_ vp: Voiceprint) -> some View {
        HStack {
            // Play the retained enrolment clip to confirm this voiceprint is the
            // right person (rename/delete to reassign if it's a mismatch).
            Button { playClip(vp) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.plain)
                .disabled(vp.audioSample == nil)
                .help(vp.audioSample == nil ? "No saved clip for this voice" : "Play the saved voice clip")

            VStack(alignment: .leading, spacing: 2) {
                Text(vp.name).font(.body.weight(.medium))
                Text("\(vp.sampleCount) sample\(vp.sampleCount == 1 ? "" : "s")"
                     + (vp.audioSample != nil ? " · clip kept" : " · no clip")
                     + " · updated \(vp.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") { renamingID = vp.id; renameText = vp.name }.font(.caption)
            Button(role: .destructive) { store.delete(vp.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func playClip(_ vp: Voiceprint) {
        guard let data = vp.audioSample else { return }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        player.play(samples: samples)
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renamingID, !name.isEmpty { store.rename(id, to: name) }
        renamingID = nil
    }

    private func exportStore() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportPassphrase.isEmpty ? "macsribe-voiceprints.json" : "macsribe-voiceprints.enc"
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
