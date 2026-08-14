import XCTest
import AppKit
@testable import Parley

final class MeetingAttachmentTests: XCTestCase {

    private var vault: URL!
    private var transcriptURL: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-attach-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let unprocessed = AppPaths.unprocessedURL(vault: vault)
        try FileManager.default.createDirectory(at: unprocessed, withIntermediateDirectories: true)
        transcriptURL = unprocessed.appendingPathComponent("2026-07-30-1015 - Whiteboard.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    func testAddFileAndSyncTranscript() throws {
        let png = try makePNGData()
        let folderID = MeetingAttachmentStore.folderID(forTranscript: transcriptURL)
        let src = MeetingAttachmentStore.folderURL(vault: vault, folderID: folderID)
            .appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: src)

        let att = try MeetingAttachmentStore.addFile(
            from: src, vault: vault, folderID: folderID, caption: "Whiteboard funnel")

        let seed = TranscriptWriter.makeBody(
            title: "Whiteboard", date: Date(), attendees: "", destination: "",
            segments: [], documentURL: transcriptURL, vaultURL: vault)
        try seed.write(to: transcriptURL, atomically: true, encoding: .utf8)

        MeetingAttachmentStore.syncTranscript(transcriptURL, vault: vault, attachments: [att])

        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(text.contains("## Attachments"))
        XCTAssertTrue(text.contains("Whiteboard funnel"))
        let meta = TranscriptWriter.parseFrontmatter(transcriptURL)
        XCTAssertEqual(meta?.attachments.count, 1)
        XCTAssertEqual(meta?.attachments.first?.caption, "Whiteboard funnel")
    }

    func testPromptBlockIncludesCaptionAndTimestamp() {
        let att = MeetingAttachment(
            filename: "board.png",
            vaultRelativePath: "Parley/Attachments/x/board.png",
            caption: "Architecture sketch",
            capturedAtOffset: 754,
            mimeType: "image/png",
            source: .paste)
        let block = MeetingAttachmentStore.promptBlock(attachments: [att])
        XCTAssertTrue(block.contains("ATTACHMENTS:"))
        XCTAssertTrue(block.contains("board.png"))
        XCTAssertTrue(block.contains("Architecture sketch"))
        XCTAssertTrue(block.contains("t=12:34"))
    }

    func testSharedVaultLinkFromFiledNote() throws {
        let folderID = "session-1"
        let png = try makePNGData()
        let srcDir = MeetingAttachmentStore.folderURL(vault: vault, folderID: folderID)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("board.png")
        try png.write(to: src)
        let att = try MeetingAttachmentStore.addFile(
            from: src, vault: vault, folderID: folderID, caption: "Board", capturedAtOffset: 10)
        let noteURL = vault.appendingPathComponent("Internal/Customers/2026-07-30 - Planning.md")
        try FileManager.default.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let filed = MeetingAttachmentStore.attachmentsForFiling(attachments: [att])
        XCTAssertEqual(filed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: att.fileURL(vault: vault).path))
        let rel = att.markdownRelativePath(from: noteURL, vault: vault)
        XCTAssertTrue(rel.contains("Parley/Attachments"))
        XCTAssertTrue(rel.contains("../"))
    }

    private func makePNGData() throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 1)
        }
        return data
    }
}
