import Foundation

/// Caches and runs attachment vision passes (Stage B/C).
enum AttachmentVisionService {

    static func visionCacheURL(for transcriptURL: URL, vault: URL) -> URL {
        AppPaths.stagingURL(vault: vault)
            .appendingPathComponent(transcriptURL.deletingPathExtension().lastPathComponent + ".attachments-vision.md")
    }

    static func fingerprint(_ attachments: [MeetingAttachment]) -> String {
        attachments.map { "\($0.id.uuidString)|\($0.vaultRelativePath)|\($0.caption)" }
            .sorted()
            .joined(separator: "\n")
    }

    static func readCache(transcriptURL: URL, vault: URL, attachments: [MeetingAttachment]) -> String? {
        let url = visionCacheURL(for: transcriptURL, vault: vault)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let separator = text.range(of: "\n---\n") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        let storedFP = String(text[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard storedFP == fingerprint(attachments) else { return nil }
        let body = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    static func writeCache(transcriptURL: URL, vault: URL, attachments: [MeetingAttachment], digest: String) {
        let url = visionCacheURL(for: transcriptURL, vault: vault)
        try? FileManager.default.createDirectory(at: AppPaths.stagingURL(vault: vault), withIntermediateDirectories: true)
        let payload = fingerprint(attachments) + "\n---\n" + digest.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try? payload.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs vision when settings allow; returns cached digest when fingerprint matches.
    static func digest(transcriptURL: URL,
                       vault: URL,
                       understanding: AttachmentUnderstanding,
                       visionBackend: SummaryBackend,
                       cursorBinary: String,
                       forceRefresh: Bool = false) -> String? {
        let attachments = TranscriptWriter.parseFrontmatter(transcriptURL)?.attachments ?? []
        guard !attachments.isEmpty else { return nil }
        guard understanding == .vision else { return nil }

        if !forceRefresh, let cached = readCache(transcriptURL: transcriptURL, vault: vault, attachments: attachments) {
            return cached
        }

        let backend = visionBackend
        switch AttachmentVisionRunner.analyze(
            attachments: attachments, vault: vault, backend: backend,
            cursorBinary: cursorBinary) {
        case .success(let digest):
            writeCache(transcriptURL: transcriptURL, vault: vault, attachments: attachments, digest: digest)
            AppLog.log("Attachment vision: analyzed \(attachments.count) image(s) for \(transcriptURL.lastPathComponent)", category: "summary")
            return digest
        case .failure(let reason):
            AppLog.log("Attachment vision failed for \(transcriptURL.lastPathComponent): \(reason)", category: "summary")
            return nil
        }
    }

    /// Inserts or replaces a `## Diagrams` section in a summary draft.
    static func mergeDiagrams(into draft: String,
                              visionDigest: String,
                              attachments: [MeetingAttachment] = [],
                              documentURL: URL? = nil,
                              vault: URL? = nil) -> String {
        guard AttachmentDiagramBuilder.isActionable(visionDigest) else { return draft }

        var section = visionDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        if let documentURL, let vault, !attachments.isEmpty {
            section = AttachmentDiagramBuilder.enrich(
                visionDigest: section, attachments: attachments,
                documentURL: documentURL, vault: vault)
        }

        var body = SummaryService.strippingDiagramsSection(draft)
        if let range = body.range(of: "\n## Attachments", options: .backwards) {
            body.insert(contentsOf: "\n\n" + section, at: range.lowerBound)
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !section.isEmpty else { return body }
        if body.isEmpty { return section }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section
    }
}
