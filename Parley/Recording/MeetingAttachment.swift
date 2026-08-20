import Foundation
import AppKit
import UniformTypeIdentifiers

/// One image attachment associated with a meeting (screenshot, whiteboard photo, etc.).
struct MeetingAttachment: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case paste, file, screenshot }

    let id: UUID
    var filename: String
    /// Path relative to the vault root, e.g. `Parley/Attachments/<folder>/image.png`.
    var vaultRelativePath: String
    var caption: String
    /// Seconds into the recording when captured (nil when added post-meeting).
    var capturedAtOffset: Double?
    var createdAt: Date
    var mimeType: String
    var source: Source

    init(id: UUID = UUID(),
         filename: String,
         vaultRelativePath: String,
         caption: String = "",
         capturedAtOffset: Double? = nil,
         createdAt: Date = Date(),
         mimeType: String,
         source: Source) {
        self.id = id
        self.filename = filename
        self.vaultRelativePath = vaultRelativePath
        self.caption = caption
        self.capturedAtOffset = capturedAtOffset
        self.createdAt = createdAt
        self.mimeType = mimeType
        self.source = source
    }

    func fileURL(vault: URL) -> URL {
        vault.appendingPathComponent(vaultRelativePath)
    }

    /// Obsidian-friendly relative path from a markdown document to this file.
    func markdownRelativePath(from documentURL: URL, vault: URL) -> String {
        MeetingAttachmentStore.relativeMarkdownPath(
            from: documentURL, to: fileURL(vault: vault))
    }

    var displayLabel: String {
        let c = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? filename : c
    }

    var capturedAtLabel: String? {
        guard let offset = capturedAtOffset, offset >= 0 else { return nil }
        let total = Int(offset.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Vault storage, import, and markdown rendering for meeting image attachments.
enum MeetingAttachmentStore {
    static let maxBytes: Int64 = 5 * 1024 * 1024
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

    // MARK: Paths

    static func attachmentsRoot(vault: URL) -> URL {
        AppPaths.appVaultFolderURL(vault: vault).appendingPathComponent("Attachments", isDirectory: true)
    }

    static func folderURL(vault: URL, folderID: String) -> URL {
        attachmentsRoot(vault: vault).appendingPathComponent(sanitizeFolderID(folderID), isDirectory: true)
    }

    static func folderID(forSession sessionID: String) -> String { sessionID }

    static func folderID(forTranscript transcriptURL: URL) -> String {
        transcriptURL.deletingPathExtension().lastPathComponent
    }

    static func noteAttachmentsFolder(noteURL: URL) -> URL {
        noteURL.deletingLastPathComponent()
            .appendingPathComponent("_attachments", isDirectory: true)
            .appendingPathComponent(noteURL.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    // MARK: Import

    enum ImportError: LocalizedError {
        case unsupportedType
        case tooLarge(Int64)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedType: return "Only PNG, JPEG, HEIC, and WebP images are supported."
            case .tooLarge(let n): return "Image exceeds the \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) limit."
            case .writeFailed: return "Could not save the attachment."
            }
        }
    }

    @discardableResult
    static func addFile(from sourceURL: URL,
                        vault: URL,
                        folderID: String,
                        caption: String = "",
                        capturedAtOffset: Double? = nil,
                        source: MeetingAttachment.Source = .file) throws -> MeetingAttachment {
        let data = try Data(contentsOf: sourceURL)
        let ext = sourceURL.pathExtension.lowercased()
        let mime = mimeType(forExtension: ext)
        guard allowedExtensions.contains(ext) else { throw ImportError.unsupportedType }
        return try writeData(data, ext: ext, mime: mime, vault: vault, folderID: folderID,
                             caption: caption, capturedAtOffset: capturedAtOffset, source: source)
    }

    @discardableResult
    static func addPasteboardImage(vault: URL,
                                   folderID: String,
                                   caption: String = "",
                                   capturedAtOffset: Double? = nil) throws -> MeetingAttachment {
        guard let image = NSImage(pasteboard: .general) ?? imageFromPasteboard() else {
            throw ImportError.unsupportedType
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw ImportError.writeFailed
        }
        return try writeData(png, ext: "png", mime: "image/png", vault: vault, folderID: folderID,
                             caption: caption, capturedAtOffset: capturedAtOffset, source: .paste)
    }

    private static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            return NSImage(data: data)
        }
        return nil
    }

    private static func writeData(_ data: Data,
                                  ext: String,
                                  mime: String,
                                  vault: URL,
                                  folderID: String,
                                  caption: String,
                                  capturedAtOffset: Double?,
                                  source: MeetingAttachment.Source) throws -> MeetingAttachment {
        guard Int64(data.count) <= maxBytes else { throw ImportError.tooLarge(maxBytes) }
        let dir = folderURL(vault: vault, folderID: folderID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = fileStamp(Date())
        let base = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "attachment" : sanitizeFilename(caption)
        var filename = "\(stamp) \(base).\(ext)"
        var dest = dir.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            filename = "\(stamp) \(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(filename)
            n += 1
        }
        guard (try? data.write(to: dest, options: .atomic)) != nil else { throw ImportError.writeFailed }
        let rel = dest.path.replacingOccurrences(of: vault.standardizedFileURL.path + "/", with: "")
        return MeetingAttachment(filename: filename, vaultRelativePath: rel, caption: caption,
                                 capturedAtOffset: capturedAtOffset, mimeType: mime, source: source)
    }

    // MARK: Transcript sync

    /// Rewrites the `## Attachments` body section and frontmatter `attachments:` list.
    static func syncTranscript(_ transcriptURL: URL, vault: URL, attachments: [MeetingAttachment]) {
        TranscriptWriter.updateFrontmatter(at: transcriptURL) { meta in
            meta.attachments = attachments
        }
        guard var text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return }
        text = replaceAttachmentsSection(in: text, attachments: attachments,
                                         documentURL: transcriptURL, vault: vault)
        try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    static func loadAttachments(from transcriptURL: URL) -> [MeetingAttachment] {
        TranscriptWriter.parseFrontmatter(transcriptURL)?.attachments ?? []
    }

    static func attachmentFolderURLs(for attachments: [MeetingAttachment], vault: URL) -> [URL] {
        var seen = Set<String>()
        return attachments.compactMap { att in
            let dir = att.fileURL(vault: vault).deletingLastPathComponent().path
            guard seen.insert(dir).inserted else { return nil }
            return URL(fileURLWithPath: dir)
        }
    }

    // MARK: Filing

    /// Returns attachments for embedding in a filed note. Files stay in the shared
    /// `Parley/Attachments/` tree — links are computed relative to the note path.
    static func attachmentsForFiling(attachments: [MeetingAttachment]) -> [MeetingAttachment] {
        attachments
    }

    /// Walks up from `documentURL`'s folder and back down to `target` for Obsidian embeds.
    static func relativeMarkdownPath(from documentURL: URL, to target: URL) -> String {
        let fromDir = documentURL.deletingLastPathComponent().standardizedFileURL
        let toFile = target.standardizedFileURL
        let fromParts = fromDir.pathComponents
        let toParts = toFile.pathComponents
        var common = 0
        let limit = min(fromParts.count, toParts.count)
        while common < limit, fromParts[common] == toParts[common] { common += 1 }
        let ups = fromParts.count - common
        let downs = toParts[common...]
        let prefix = String(repeating: "../", count: ups)
        return prefix + downs.joined(separator: "/")
    }

    // MARK: Markdown

    static func renderSection(attachments: [MeetingAttachment],
                              documentURL: URL,
                              vault: URL) -> String? {
        guard !attachments.isEmpty else { return nil }
        var lines = ["## Attachments", ""]
        for att in attachments {
            let rel = att.markdownRelativePath(from: documentURL, vault: vault)
            let alt = att.displayLabel.replacingOccurrences(of: "\"", with: "'")
            lines.append("![\(alt)](\(rel))")
            lines.append("")
            if let stamp = att.capturedAtLabel {
                lines.append("> Captured at \(stamp) into the meeting")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func promptBlock(attachments: [MeetingAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        var lines = ["ATTACHMENTS:"]
        for att in attachments {
            var line = "- \(att.filename)"
            if let stamp = att.capturedAtLabel { line += " (t=\(stamp))" }
            let cap = att.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cap.isEmpty { line += ": \"\(cap)\"" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func openImagePicker() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    // MARK: Private helpers

    private static func replaceAttachmentsSection(in text: String,
                                                  attachments: [MeetingAttachment],
                                                  documentURL: URL,
                                                  vault: URL) -> String {
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Attachments" }) {
            var end = lines.count
            var j = start + 1
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("## ") { end = j; break }
                j += 1
            }
            lines.removeSubrange(start..<end)
            if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: start - 1)
            }
        }

        guard let section = renderSection(attachments: attachments, documentURL: documentURL, vault: vault) else {
            return lines.joined(separator: "\n")
        }

        // Insert before ## Transcript (or ## Notes for manual-only), else before EOF.
        let insertAt: Int
        if let tIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Transcript" }) {
            insertAt = tIdx
        } else if let nIdx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "## Notes" || t == "## Notes (manual)"
        }) {
            insertAt = nIdx
        } else {
            insertAt = lines.count
        }
        let block = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if insertAt > 0, !lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert("", at: insertAt)
            lines.insert(contentsOf: block, at: insertAt)
        } else {
            lines.insert(contentsOf: block, at: insertAt)
            if insertAt + block.count < lines.count { lines.insert("", at: insertAt + block.count) }
        }
        return lines.joined(separator: "\n")
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }

    static func sanitizeFolderID(_ id: String) -> String {
        TranscriptWriter.sanitize(id)
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let safe = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return safe.isEmpty ? "attachment" : String(safe.prefix(48))
    }
}
