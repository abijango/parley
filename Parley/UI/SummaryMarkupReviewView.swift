import SwiftUI
import MarkdownUI

/// Markup review for Summary v2: preview / edit the note, apply find-correct,
/// review checker hunks, remember customer-scoped terminology, then file.
struct SummaryMarkupReviewView: View {
    let item: TranscriptItem
    @Binding var reviewDestination: String
    @ObservedObject private var summaryService = RecordingController.shared.summaryService
    @EnvironmentObject private var vault: VaultDirectory
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedRunID: String?
    @State private var hunks: [SummaryHunk] = []
    /// Writer draft (basis for checker hunks). Updated when the user edits or corrects.
    @State private var draft: String = ""
    @State private var isEditing = false
    @State private var editingHunkID: String?
    @State private var editDraft: String = ""
    @State private var showCorrectSheet = false
    @State private var correctFrom = ""
    @State private var correctTo = ""
    @State private var correctNotes = ""
    @State private var rememberCorrection = true
    @State private var statusMessage: String?
    /// Editable buffer while in Edit mode (flattened note).
    @State private var editBuffer: String = ""

    private let runStore = SummaryRunStore()
    private let terminologyStore = TerminologyStore()

    private var runs: [SummaryRunRecord] {
        runStore.runs(forTranscriptID: item.url.path)
    }

    private var customerScope: String {
        TerminologyStore.customerScope(fromFiling: reviewDestination.isEmpty ? item.meta.filing : reviewDestination)
    }

    /// Body shown in preview/edit — draft with pending+accepted hunks applied.
    private var workingBody: String {
        var applied = hunks
        for i in applied.indices where applied[i].status == .pending {
            applied[i].status = .accepted
        }
        return SummaryHunkEngine.mergedMarkdown(draft: draft, hunks: applied)
    }

    /// Binding that seeds/commits the edit buffer *before* flipping modes so the
    /// TextEditor never paints empty and Preview always sees the saved draft.
    private var editingMode: Binding<Bool> {
        Binding(
            get: { isEditing },
            set: { newValue in
                if newValue {
                    editBuffer = workingBody
                    isEditing = true
                } else {
                    commitEditBuffer()
                    isEditing = false
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                documentPane
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                sidePane
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { loadLatestRun() }
        .sheet(isPresented: $showCorrectSheet) { correctSheet }
        .sheet(isPresented: Binding(
            get: { editingHunkID != nil },
            set: { if !$0 { editingHunkID = nil } }
        )) { hunkEditSheet }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text("Summary v2 — edit the note, correct terminology, then file.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Mode", selection: editingMode) {
                    Text("Preview").tag(false)
                    Text("Edit").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
            if runs.count > 1 {
                Picker("Run history", selection: Binding(
                    get: { selectedRunID ?? runs.first?.id ?? "" },
                    set: { selectedRunID = $0; loadRun(id: $0) }
                )) {
                    ForEach(runs) { run in
                        Text(runLabel(run)).tag(run.id)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack(spacing: Theme.Spacing.small) {
                Text("Will be filed to:")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                DestinationField(path: $reviewDestination,
                                 destinations: vault.destinations,
                                 firstRoot: settings.scanRoots.first ?? "Internal")
                if !customerScope.isEmpty {
                    Text("Scope: \(customerScope)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .help("Terminology remembered here applies only to this customer folder")
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
        .chromeSurface()
    }

    // MARK: Document

    @ViewBuilder
    private var documentPane: some View {
        if isEditing {
            TextEditor(text: $editBuffer)
                .font(Theme.Typography.mono)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hunks.contains(where: { $0.status != .rejected }) {
            markupDocument
        } else {
            ScrollView {
                Markdown(workingBody)
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var markupDocument: some View {
        ScrollView {
            let segments = SummaryHunkEngine.previewSegments(draft: draft, hunks: hunks)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: SummaryMarkupSegment) -> some View {
        switch segment {
        case .plain(let text):
            Markdown(text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .insertion(let text, _, let reason):
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.red)
                    .fontWeight(.medium)
                if !reason.isEmpty { changeReasonLabel("Added — \(reason)") }
            }
            .padding(6)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

        case .deletion(let text, _, let reason):
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .strikethrough(true, color: .red)
                if !reason.isEmpty { changeReasonLabel("Removed — \(reason)") }
            }
            .padding(6)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))

        case .replacement(let old, let new, _, let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: old)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .strikethrough(true, color: .red)
                Text(verbatim: new)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.red)
                    .fontWeight(.medium)
                if !reason.isEmpty { changeReasonLabel("Corrected — \(reason)") }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
        }
    }

    private func changeReasonLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Color.red.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Side pane

    private var sidePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Corrections")
                    .font(Theme.Typography.controlLabel)
                Spacer()
                Button {
                    correctFrom = ""
                    correctTo = ""
                    correctNotes = defaultCorrectNotes()
                    rememberCorrection = true
                    showCorrectSheet = true
                } label: {
                    Label("Correct…", systemImage: "pencil.and.list.clipboard")
                }
                .help("Find & replace in the note (e.g. Maya → Maia) and optionally remember for this customer")
            }
            .padding(Theme.Spacing.small)
            Divider()
            List {
                if hunks.isEmpty {
                    Text("No checker edits yet. Use Edit or Correct… to fix the draft yourself.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(hunks) { hunk in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        HStack {
                            Text(hunk.op.rawValue.capitalized)
                                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                            Spacer()
                            statusChip(hunk.status)
                        }
                        if !hunk.reason.isEmpty {
                            Text(hunk.reason).font(Theme.Typography.caption)
                        }
                        Text(hunkSummary(hunk))
                            .font(Theme.Typography.mono)
                            .lineLimit(4)
                        HStack(spacing: Theme.Spacing.small) {
                            Button("Accept") { setStatus(hunk, .accepted) }
                                .disabled(hunk.status == .accepted)
                            Button("Reject") { setStatus(hunk, .rejected) }
                                .disabled(hunk.status == .rejected)
                            Button("Edit") { beginEdit(hunk) }
                            if hunk.op == .replace {
                                Button("Remember") { rememberTerminology(hunk) }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(Theme.Typography.caption)
                    }
                    .padding(.vertical, Theme.Spacing.xSmall)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Sheets

    private var correctSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Correct terminology").font(Theme.Typography.sectionHeader)
            Text("Replaces whole-word matches in the note. Remembered corrections apply only under “\(customerScope.isEmpty ? "this filing path" : customerScope)”.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Find") {
                TextField("Maya", text: $correctFrom)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Replace with") {
                TextField("Maia", text: $correctTo)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Notes") {
                TextField("platform name, not a person", text: $correctNotes)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Remember for \(customerScope.isEmpty ? "this customer" : customerScope)", isOn: $rememberCorrection)
            HStack {
                Spacer()
                Button("Cancel") { showCorrectSheet = false }
                Button("Apply") { applyCorrection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(correctFrom.trimmingCharacters(in: .whitespaces).isEmpty
                              || correctTo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 460)
    }

    private var hunkEditSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Edit hunk text").font(Theme.Typography.sectionHeader)
            TextEditor(text: $editDraft)
                .font(Theme.Typography.mono)
                .frame(minHeight: 120)
            HStack {
                Spacer()
                Button("Cancel") { editingHunkID = nil }
                Button("Save") { saveHunkEdit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button(role: .destructive) { summaryService.discard(item) } label: {
                Label("Discard", systemImage: "trash")
            }
            .glassButton()
            Button { summaryService.regenerate(item) } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .glassButton()
            Button {
                editingMode.wrappedValue = true
            } label: {
                Label("Edit note", systemImage: "square.and.pencil")
            }
            .glassButton()
            Spacer()
            Button { acceptAndFile() } label: {
                Label("Accept & File", systemImage: "tray.and.arrow.down")
            }
            .glassProminentButton()
        }
        .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
        .chromeSurface()
    }

    // MARK: Load / persist

    private func runLabel(_ run: SummaryRunRecord) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return "\(df.string(from: run.createdAt)) — \(run.writerBackend) → \(run.checkerBackend)"
    }

    private func loadLatestRun() {
        guard let run = runs.first else {
            if let staged = item.summaryReadyURL,
               let text = try? String(contentsOf: staged, encoding: .utf8) {
                draft = text
            }
            return
        }
        selectedRunID = run.id
        loadRun(id: run.id)
    }

    private func loadRun(id: String) {
        guard let run = runStore.run(id: id) else { return }
        draft = run.draftMarkdown
        hunks = runStore.hunks(forRunID: id)
        editBuffer = ""
        isEditing = false
    }

    private func commitEditBuffer() {
        // Always bake the editor contents into `draft` when leaving Edit — including
        // an intentionally emptied note — so Preview never flashes stale/blank state.
        guard isEditing || !editBuffer.isEmpty else { return }
        draft = editBuffer
        hunks = []
        if let runID = selectedRunID {
            runStore.replaceHunks(runID: runID, hunks: [])
            runStore.updateDraftMarkdown(runID: runID, markdown: draft)
            summaryService.refreshV2Staging(transcriptURL: item.url, runID: runID)
        }
        statusMessage = "Note updated."
    }

    // MARK: Correct

    private func defaultCorrectNotes() -> String {
        let sample = correctFrom.isEmpty ? "the original spelling" : correctFrom
        if customerScope.isEmpty {
            return "Preferred spelling for this customer; do not rename a person named \(sample)."
        }
        return "\(customerScope): preferred spelling for the platform/product — do not rename a person named \(sample)."
    }

    private func applyCorrection() {
        let from = correctFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = correctTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }

        if isEditing {
            commitEditBuffer()
            isEditing = false
        }

        let base = workingBody
        let (replaced, count) = Self.replacingWholeWords(in: base, from: from, to: to)
        guard count > 0 else {
            statusMessage = "No whole-word matches for “\(from)”."
            showCorrectSheet = false
            return
        }

        draft = replaced
        editBuffer = ""
        hunks = []
        if let runID = selectedRunID {
            runStore.replaceHunks(runID: runID, hunks: [])
            runStore.updateDraftMarkdown(runID: runID, markdown: draft)
            summaryService.refreshV2Staging(transcriptURL: item.url, runID: runID)
        }

        if rememberCorrection {
            let notes = correctNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultCorrectNotes()
                : correctNotes
            terminologyStore.upsert(
                from: from,
                to: to,
                notes: notes,
                source: "human-review",
                scope: customerScope
            )
        }

        statusMessage = "Replaced \(count)× “\(from)” → “\(to)”"
            + (rememberCorrection ? " · remembered for \(customerScope.isEmpty ? "this path" : customerScope)" : "")
        showCorrectSheet = false
    }

    /// Whole-word, case-sensitive replace (keeps “Mayan” etc. intact).
    static func replacingWholeWords(in text: String, from: String, to: String) -> (String, Int) {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: from))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, 0)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.numberOfMatches(in: text, range: range)
        let out = regex.stringByReplacingMatches(
            in: text, range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: to))
        return (out, matches)
    }

    // MARK: Hunks

    private func hunkSummary(_ hunk: SummaryHunk) -> String {
        switch hunk.op {
        case .replace: return "\"\(hunk.target)\" → \"\(hunk.effectiveText)\""
        case .delete: return "delete \"\(hunk.target)\""
        case .insert: return "after \"\(hunk.afterAnchor.isEmpty ? hunk.target : hunk.afterAnchor)\": \"\(hunk.effectiveText)\""
        }
    }

    private func statusChip(_ status: SummaryHunkStatus) -> some View {
        let label: String
        let color: Color
        switch status {
        case .pending: label = "Pending"; color = .orange
        case .accepted: label = "Accepted"; color = .green
        case .rejected: label = "Rejected"; color = .secondary
        }
        return Text(label).font(Theme.Typography.caption).foregroundStyle(color)
    }

    private func setStatus(_ hunk: SummaryHunk, _ status: SummaryHunkStatus) {
        guard let i = hunks.firstIndex(where: { $0.id == hunk.id }) else { return }
        hunks[i].status = status
        runStore.updateHunk(hunks[i])
        editBuffer = ""
        if let runID = selectedRunID {
            summaryService.refreshV2Staging(transcriptURL: item.url, runID: runID)
        }
    }

    private func beginEdit(_ hunk: SummaryHunk) {
        editingHunkID = hunk.id
        editDraft = hunk.effectiveText
    }

    private func saveHunkEdit() {
        guard let id = editingHunkID, let i = hunks.firstIndex(where: { $0.id == id }) else { return }
        hunks[i].overrideText = editDraft
        hunks[i].status = .accepted
        runStore.updateHunk(hunks[i])
        editBuffer = ""
        if let runID = selectedRunID {
            summaryService.refreshV2Staging(transcriptURL: item.url, runID: runID)
        }
        editingHunkID = nil
    }

    private func rememberTerminology(_ hunk: SummaryHunk) {
        guard hunk.op == .replace else { return }
        let from = hunk.target
        let to = hunk.effectiveText
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        let notes = hunk.reason.isEmpty
            ? "\(customerScope) correction; do not rename a person named \(from)."
            : hunk.reason
        terminologyStore.upsert(from: from, to: to, notes: notes, source: "summary-hunk:\(hunk.id)",
                                scope: customerScope)
        statusMessage = "Remembered “\(from)” → “\(to)” for \(customerScope.isEmpty ? "this path" : customerScope)"
    }

    private func acceptAndFile() {
        if isEditing {
            commitEditBuffer()
            isEditing = false
        }
        var toFile = hunks
        for i in toFile.indices where toFile[i].status == .pending {
            toFile[i].status = .accepted
            runStore.updateHunk(toFile[i])
        }
        hunks = toFile
        let body = SummaryHunkEngine.mergedMarkdown(draft: draft, hunks: toFile)
        if let runID = selectedRunID {
            summaryService.refreshV2Staging(transcriptURL: item.url, runID: runID)
        }
        _ = summaryService.commitGeneratedMarkdown(
            item,
            destination: reviewDestination,
            body: body,
            overwriteExisting: false
        )
    }
}
