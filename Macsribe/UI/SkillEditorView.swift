import SwiftUI
import AppKit

/// In-app editor for the `process-meeting-transcript` SKILL.md. Reads/writes the
/// real file (the same one Claude Code uses), so edits take effect on the next
/// `claude -p` run. Path is configurable.
struct SkillEditorView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var text = ""
    @State private var status: String?
    @State private var isDirty = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skill instructions").font(.headline)
                Spacer()
                Button("Reload") { load() }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([settings.skillURL]) }
            }

            TextField("Skill file path", text: $settings.skillPath)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { load() }

            if !text.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") {
                Label("Missing YAML frontmatter (--- name: … ---) — Claude needs it to find this skill.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                .border(.quaternary)
                .onChange(of: text) { isDirty = true }

            HStack {
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(!isDirty)
            }
        }
        .onAppear { if !loaded { load(); loaded = true } }
    }

    private func load() {
        do {
            text = try String(contentsOf: settings.skillURL, encoding: .utf8)
            isDirty = false
            status = "Loaded \(settings.skillURL.lastPathComponent)"
        } catch {
            text = ""
            status = "Couldn't read the skill file: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: settings.skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: settings.skillURL, atomically: true, encoding: .utf8)
            isDirty = false
            status = "Saved — takes effect on the next notes run."
            AppLog.log("Skill saved: \(settings.skillURL.path)", category: "claude")
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
