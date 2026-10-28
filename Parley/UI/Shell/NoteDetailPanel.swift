import SwiftUI

// MARK: - Note detail: right panel + summary review in the center
//
// For a selected meeting, the center shows the title header and the transcript; the
// notes panel holds Details (filing, attendees, attachments, files) and a read-only
// Summary preview. A staged summary's full review opens into the center on demand.

extension HistoryView {

    func notePanel(_ item: TranscriptItem) -> some View {
        NotesPanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotesPanelSection("Details", symbol: "doc.text", isExpanded: $noteDetailsExpanded) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                                Text("Filing").font(Theme.Typography.fieldLabel).foregroundStyle(.secondary)
                                DestinationField(path: headerFilingBinding(for: item),
                                                 destinations: vault.destinations,
                                                 firstRoot: settings.scanRoots.first ?? "Internal")
                            }
                            attendeesEditor(item)
                            historyAttachmentsEditor(item)
                            filesStrip(item)
                        }
                    }
                    NotesPanelSection("Summary", symbol: "sparkles", isExpanded: $noteSummaryExpanded) {
                        noteSummarySection(item)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// Read-only summary for the panel: the staged summary (with a button to open its
    /// review in the center), else the filed note, else a hint to summarize.
    @ViewBuilder func noteSummarySection(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            summaryStatusBar(item)
            if let staged = item.summaryReadyURL {
                Text("Ready to review — check it, set where it's filed, then commit.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                summaryPreview(staged)
                Button {
                    withAnimation(Theme.Motion.quick) { summaryInCenter = true }
                } label: {
                    Label("Open review", systemImage: "arrow.left.and.right.square")
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .disabled(summaryInCenter)
            } else if let note = filedNoteURL(item) {
                summaryPreview(note)
                Button {
                    Obsidian.open(note)
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .glassButton()
            } else {
                Text(isPending(item)
                     ? "Generating notes…"
                     : "No summary yet. Use Summarize above to generate meeting notes.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func summaryPreview(_ url: URL) -> some View {
        TranscriptPreviewView(url: url, reloadToken: recording.transcriptRevision)
            .frame(height: 420)
            .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.panelBg))
            .clipShape(Theme.Radius.rect(Theme.Radius.small))
            .overlay(Theme.Radius.rect(Theme.Radius.small)
                .strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
    }

    func filedNoteURL(_ item: TranscriptItem) -> URL? {
        guard let path = item.meta.note, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The staged summary's full review, opened into the center in place of the
    /// transcript, with a way back.
    @ViewBuilder func summaryReviewCenter(_ item: TranscriptItem, staged: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(Theme.Motion.quick) { summaryInCenter = false }
                } label: {
                    Label("Back to transcript", systemImage: "chevron.left")
                }
                .glassButton()
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.small)
            Divider()
            if isV2Review(item: item, staged: staged) {
                SummaryMarkupReviewView(item: item, reviewDestination: $reviewDestination)
            } else {
                reviewPane(item, staged: staged)
            }
        }
    }
}
