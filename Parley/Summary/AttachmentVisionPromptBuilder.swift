import Foundation

/// Builds the prompt for a vision-only pass over meeting image attachments.
enum AttachmentVisionPromptBuilder {

    static let defaultInstructions = """
    You are analyzing meeting attachment images (screenshots, whiteboard photos, slides). \
    Open and read each image file listed below using your vision capabilities.

    Output ONLY Markdown — no preamble, no JSON, no commentary outside the note body.

    Structure your output as:

    ## Diagrams

    For each image that is clearly a diagram, whiteboard, architecture sketch, flowchart, \
    or slide with structure:
    - A `###` subheading: `<filename> — <short title>`
    - 1–3 sentences describing what the image shows (text visible, relationships, labels).
    - If the image is diagram-like, add a fenced ```mermaid block recreating the structure \
    as faithfully as possible. Use flowchart, sequenceDiagram, or classDiagram as appropriate.
    - If the image is a plain screenshot or photo with no diagram structure, describe it \
    under the subheading but do NOT add mermaid.

    Rules:
    - Read the actual pixels — do not invent content not visible in the image.
    - Prefer readable text from the image over guessing.
    - Keep mermaid simple; omit styling directives.
    - If none of the images warrant a diagram section, output exactly: ## Diagrams\\n\\nNone recorded.
    - Do NOT output ## Attachments — Parley embeds the raw images separately.
    """

    static func build(attachments: [MeetingAttachment], vault: URL, instructions: String = defaultInstructions) -> String {
        let head = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [head, "", "IMAGE FILES (absolute paths — read each with vision):"]
        for att in attachments {
            let path = att.fileURL(vault: vault).path
            var line = "- \(path)"
            let cap = att.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cap.isEmpty { line += " — caption: \"\(cap)\"" }
            if let stamp = att.capturedAtLabel { line += " (captured at \(stamp) into meeting)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
