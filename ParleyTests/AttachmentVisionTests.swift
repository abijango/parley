import XCTest
@testable import Parley

final class AttachmentVisionTests: XCTestCase {

    func testVisionPromptListsImagePaths() {
        let vault = URL(fileURLWithPath: "/tmp/vault")
        let att = MeetingAttachment(
            filename: "board.png",
            vaultRelativePath: "Parley/Attachments/x/board.png",
            caption: "Whiteboard",
            capturedAtOffset: 125,
            mimeType: "image/png",
            source: .paste)
        let prompt = AttachmentVisionPromptBuilder.build(attachments: [att], vault: vault)
        XCTAssertTrue(prompt.contains("## Diagrams"))
        XCTAssertTrue(prompt.contains("/tmp/vault/Parley/Attachments/x/board.png"))
        XCTAssertTrue(prompt.contains("Whiteboard"))
    }

    func testInjectVisionDigestBeforeTranscript() {
        let template = "Hello\n\nTRANSCRIPT:\n{{transcript}}"
        let built = SummaryPromptBuilder.build(
            template: template,
            transcriptURL: URL(fileURLWithPath: "/tmp/none.md"),
            attendees: "",
            destination: "",
            contactsURL: nil,
            visionDigest: "## Diagrams\n\n### board — test",
            attachmentUnderstanding: .captionsOnly)
        XCTAssertTrue(built.prompt.contains("ATTACHMENT VISION"))
        XCTAssertTrue(built.prompt.contains("## Diagrams"))
        XCTAssertLessThan(
            built.prompt.range(of: "ATTACHMENT VISION")!.lowerBound,
            built.prompt.range(of: "TRANSCRIPT:")!.lowerBound)
    }

    func testMergeDiagramsReplacesExistingSection() {
        let draft = """
        ## Executive Summary
        Hello.

        ## Diagrams

        ### old
        stale
        """
        let merged = AttachmentVisionService.mergeDiagrams(
            into: draft, visionDigest: "## Diagrams\n\n### new\nfresh")
        XCTAssertTrue(merged.contains("### new"))
        XCTAssertFalse(merged.contains("stale"))
        XCTAssertTrue(merged.contains("## Executive Summary"))
    }

    func testEnrichDiagramsAppendsImageEmbed() {
        let vault = URL(fileURLWithPath: "/vault")
        let note = vault.appendingPathComponent("Internal/2026-07-30 - Planning.md")
        let att = MeetingAttachment(
            filename: "board.png",
            vaultRelativePath: "Parley/Attachments/x/board.png",
            caption: "Whiteboard funnel",
            capturedAtOffset: nil,
            mimeType: "image/png",
            source: .paste)
        let vision = """
        ## Diagrams

        ### board.png — Funnel
        Three stages drawn left to right.

        ```mermaid
        flowchart LR
          A --> B --> C
        ```
        """
        let enriched = AttachmentDiagramBuilder.enrich(
            visionDigest: vision, attachments: [att], documentURL: note, vault: vault)
        XCTAssertTrue(enriched.contains("![Whiteboard funnel]"))
        XCTAssertTrue(enriched.contains("Parley/Attachments/x/board.png"))
    }

    func testMergeDiagramsInsertsBeforeAttachments() {
        let vault = URL(fileURLWithPath: "/vault")
        let note = vault.appendingPathComponent("Eng/note.md")
        let att = MeetingAttachment(
            filename: "sketch.png",
            vaultRelativePath: "Parley/Attachments/id/sketch.png",
            caption: "Sketch",
            capturedAtOffset: nil,
            mimeType: "image/png",
            source: .file)
        let draft = """
        ## Executive Summary
        Hello.

        ## Attachments

        ![Sketch](../Parley/Attachments/id/sketch.png)
        """
        let merged = AttachmentVisionService.mergeDiagrams(
            into: draft,
            visionDigest: "## Diagrams\n\n### sketch.png — Layout\nBoxes and arrows.",
            attachments: [att],
            documentURL: note,
            vault: vault)
        guard let diagrams = merged.range(of: "## Diagrams"),
              let attachments = merged.range(of: "## Attachments") else {
            return XCTFail("missing sections")
        }
        XCTAssertLessThan(diagrams.lowerBound, attachments.lowerBound)
        XCTAssertTrue(merged.contains("![Sketch]"))
    }

    func testNoneRecordedDigestIsSkipped() {
        let draft = "## Executive Summary\nHello."
        let merged = AttachmentVisionService.mergeDiagrams(
            into: draft, visionDigest: "## Diagrams\n\nNone recorded.")
        XCTAssertEqual(merged, draft)
    }

    func testRelativeMarkdownPathFromNestedNote() {
        let vault = URL(fileURLWithPath: "/vault")
        let note = vault.appendingPathComponent("Internal/Customers/note.md")
        let image = vault.appendingPathComponent("Parley/Attachments/id/img.png")
        let rel = MeetingAttachmentStore.relativeMarkdownPath(from: note, to: image)
        XCTAssertTrue(rel.contains("../"))
        XCTAssertTrue(rel.hasSuffix("Parley/Attachments/id/img.png"))
    }
}
