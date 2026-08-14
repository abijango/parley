import SwiftUI
import AppKit

/// Thumbnail strip + add controls for meeting image attachments (live session or History).
struct MeetingAttachmentsView: View {
    let attachments: [MeetingAttachment]
    let vaultURL: URL
    var onPaste: () -> Void
    var onPickFiles: () -> Void
    var onRemove: (UUID) -> Void
    var onCaptionChange: ((UUID, String) -> Void)?

    private let thumbSize: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Text("Attachments").font(Theme.Typography.fieldLabel).foregroundStyle(.secondary)
                Spacer()
                Button(action: onPaste) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.chip)
                .help("Paste an image from the clipboard")
                Button(action: onPickFiles) {
                    Label("Add…", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.chip)
                .help("Add image files (PNG, JPEG, HEIC, WebP)")
            }

            if attachments.isEmpty {
                Text("Screenshots and whiteboard photos appear here and in the filed Obsidian note.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(attachments) { att in
                            attachmentTile(att)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentTile(_ att: MeetingAttachment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            ZStack(alignment: .topTrailing) {
                AttachmentThumbnail(url: att.fileURL(vault: vaultURL), size: thumbSize)
                Button {
                    onRemove(att.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Remove attachment")
            }
            if let onCaptionChange {
                TextField("Caption", text: captionBinding(for: att, onChange: onCaptionChange))
                    .font(Theme.Typography.caption)
                    .textFieldStyle(.plain)
                    .frame(width: thumbSize + 8)
            } else {
                Text(att.displayLabel)
                    .font(Theme.Typography.caption)
                    .lineLimit(2)
                    .frame(width: thumbSize + 8, alignment: .leading)
            }
            if let stamp = att.capturedAtLabel {
                Text(stamp)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func captionBinding(for att: MeetingAttachment,
                                onChange: @escaping (UUID, String) -> Void) -> Binding<String> {
        Binding(
            get: { att.caption },
            set: { onChange(att.id, $0) }
        )
    }
}

private struct AttachmentThumbnail: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(.quaternary))
    }
}
