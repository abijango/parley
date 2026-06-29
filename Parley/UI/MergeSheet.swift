import SwiftUI

/// Sheet for the "Combine with…" action: lets the user pick which other recording(s) to
/// combine with the base leg, choose a merge backend (Audio re-pass vs Transcript stitch),
/// and review the implications before confirming.
///
/// The caller (HistoryView.mergeSheetView) passes the base item, a sorted list of
/// candidates, a pre-selected set of sibling IDs (same title, within 5 minutes), and an
/// explicit RecordingController reference so this sheet never relies on EnvironmentObject.
/// On completion it calls `onComplete` with the combined note URL (or nil on cancellation /
/// failure); the caller owns selection / filter updates.
struct MergeSheet: View {

    let base: TranscriptItem
    let candidates: [TranscriptItem]
    let initialSelection: Set<TranscriptItem.ID>
    let recording: RecordingController
    let onComplete: (URL?) -> Void

    // MARK: - Local state

    /// IDs of other legs the user has picked.
    @State private var picked: Set<TranscriptItem.ID>
    /// Explicit user preference for the backend (nil = user hasn't overridden, use auto).
    @State private var userBackendChoice: MergeBackend? = nil
    /// True while the async merge is running.
    @State private var isMerging = false

    // MARK: - Init

    init(
        base: TranscriptItem,
        candidates: [TranscriptItem],
        initialSelection: Set<TranscriptItem.ID>,
        recording: RecordingController,
        onComplete: @escaping (URL?) -> Void
    ) {
        self.base = base
        self.candidates = candidates
        self.initialSelection = initialSelection
        self.recording = recording
        self.onComplete = onComplete
        _picked = State(initialValue: initialSelection)
    }

    // MARK: - Derived helpers

    /// All legs in date order: base + picked candidates.
    private var orderedLegs: [TranscriptItem] {
        let pickedItems = candidates.filter { picked.contains($0.id) }
        return ([base] + pickedItems).sorted { $0.meta.date < $1.meta.date }
    }

    /// True when every selected leg (base + all picked) has audio on disk.
    private var allLegsHaveAudio: Bool {
        orderedLegs.allSatisfy { audioAvailable($0) }
    }

    /// The backend that will actually be used after applying the user's choice and the
    /// "audio re-pass requires audio" constraint.
    private var effectiveBackend: MergeBackend {
        // If audio re-pass is unavailable (any leg missing audio), always fall back to stitch.
        guard allLegsHaveAudio else { return .transcriptStitch }
        // Honour the user's explicit pick; default to audio re-pass when audio is present.
        return userBackendChoice ?? .audioRepass
    }

    /// Whether the confirm button should be enabled (at least one other leg selected,
    /// not already running).
    private var canConfirm: Bool {
        !picked.isEmpty && !isMerging
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    baseSection
                    candidatesSection
                    backendSection
                }
                .padding(Theme.Spacing.large)
            }
            Divider()
            footer
        }
        .frame(width: 480)
        // Constrain height: enough for ~6 candidate rows + header + footer.
        .frame(minHeight: 380, maxHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text("Combine with\u{2026}").font(Theme.Typography.sheetTitle)
            Text("Select the other recording(s) from the same call to combine with this one. The result is a single note covering the full session.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.large)
    }

    // MARK: - Base item display

    private var baseSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text("Base recording")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
            legRow(base, isBase: true, isChecked: .constant(true))
        }
    }

    // MARK: - Candidate picker

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text("Other recordings to include")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No other recordings found in the vault.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Spacing.xSmall)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        let isChecked = Binding<Bool>(
                            get: { picked.contains(candidate.id) },
                            set: { on in
                                if on { picked.insert(candidate.id) }
                                else { picked.remove(candidate.id) }
                            }
                        )
                        legRow(candidate, isBase: false, isChecked: isChecked)
                        if candidate.id != candidates.last?.id {
                            Divider().padding(.leading, Theme.Spacing.xLarge)
                        }
                    }
                }
                .background(.quaternary.opacity(Theme.Opacity.surface), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// A single leg row: checkbox (or a fixed "Base" chip), title, date, audio indicator.
    @ViewBuilder
    private func legRow(
        _ item: TranscriptItem,
        isBase: Bool,
        isChecked: Binding<Bool>
    ) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            if isBase {
                Text("Base")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .center)
            } else {
                Toggle("", isOn: isChecked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 36, alignment: .center)
                    .disabled(isMerging)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.meta.title)
                    .font(Theme.Typography.controlLabel).lineLimit(1)
                Text(Self.dateString(item.meta.date))
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
            }

            Spacer()

            if audioAvailable(item) {
                Image(systemName: "waveform")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    .help("Audio available")
            } else {
                Image(systemName: "waveform.slash")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    .help("Audio not available")
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xSmall)
    }

    // MARK: - Backend picker

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Combine method")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                // Audio re-pass option
                backendOption(
                    label: "Audio re-pass (recommended)",
                    detail: "Concatenates the raw audio with silence-padded gaps, then runs a fresh transcription and diarization pass over the whole meeting — producing consistent speaker labels end-to-end.",
                    backend: .audioRepass,
                    isDisabled: !allLegsHaveAudio,
                    disabledHint: allLegsHaveAudio ? nil : "Audio is missing for one or more legs — switch to Transcript stitch or re-run from audio if available."
                )

                backendOption(
                    label: "Transcript stitch",
                    detail: "Stitches the existing transcripts in time order behind a reconnected marker. Works even after audio has been deleted. Speaker labels are not unified across the join — names from each leg remain independent.",
                    backend: .transcriptStitch,
                    isDisabled: false,
                    disabledHint: nil
                )
            }
            .background(.quaternary.opacity(Theme.Opacity.surface), in: RoundedRectangle(cornerRadius: 6))

            if effectiveBackend == .transcriptStitch {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Severity.warning.color)
                        .font(Theme.Typography.captionSecondary)
                    Text("Speaker labels are not unified across the join — each leg keeps its own speaker numbering at the seam.")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func backendOption(
        label: String,
        detail: String,
        backend: MergeBackend,
        isDisabled: Bool,
        disabledHint: String?
    ) -> some View {
        let isSelected = effectiveBackend == backend
        Button {
            guard !isDisabled else { return }
            userBackendChoice = backend
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.Palette.accent : .secondary)
                    .font(.body)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Theme.Typography.controlLabel)
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                    Text(isDisabled ? (disabledHint ?? detail) : detail)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isMerging)
        .opacity(isDisabled ? 0.6 : 1.0)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if isMerging {
                ProgressView().controlSize(.small).scaleEffect(0.8, anchor: .center)
                Text("Combining\u{2026}")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onComplete(nil) }
                .glassButton()
                .disabled(isMerging)
            Button("Combine") { confirm() }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .chromeSurface()
    }

    // MARK: - Actions

    private func confirm() {
        guard canConfirm else { return }
        let legs = orderedLegs
        let backend = effectiveBackend
        isMerging = true
        Task {
            let result = await recording.combineRecordings(legs, backend: backend)
            await MainActor.run {
                isMerging = false
                onComplete(result)
            }
        }
    }

    // MARK: - Helpers

    /// Returns true when the item's audio file is present on disk. Mirrors
    /// HistoryView.audioAvailable — replicated here because that method is private.
    private func audioAvailable(_ item: TranscriptItem) -> Bool {
        guard let a = item.meta.audio, !a.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: a)
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
