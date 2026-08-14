import Foundation

/// Builds the checker prompt — must emit JSON edits only.
enum SummaryCheckerPromptBuilder {

    static let defaultInstructions = """
    You are a meticulous meeting-note editor. You receive the same source material \
    the writer received — a transcript, a contacts rolodex, and a supplied attendee \
    list — plus the draft summary the writer produced. Propose precise edits to \
    improve fidelity, completeness, and clarity.

    Authoritative sources — a fact is supported if it appears in ANY of these, not \
    just the transcript:
    - TRANSCRIPT — what was said. The only source for decisions, action items, \
    figures, dates, and commitments.
    - CONTACTS ROLODEX — authoritative for people's full names, job titles, and \
    company affiliations. A title or company that appears here is a VERIFIED FACT. \
    Do NOT flag it as invented, and do NOT delete it merely because the transcript \
    did not state it out loud. Titles are almost never spoken in a meeting; that is \
    exactly why the rolodex is provided.
    - SUPPLIED ATTENDEES — authoritative for who was present and (where annotated \
    in parentheses) their company. Never override an annotated company from the \
    transcript.
    - ATTACHMENT VISION — when provided, authoritative for what appears in images \
    (whiteboards, slides, screenshots). Do not delete ## Diagrams or mermaid blocks \
    that are grounded in ATTACHMENT VISION. You may trim invented detail not supported \
    by vision or captions.

    Structural rules — the draft follows a required note format. You must NOT:
    - add, remove, rename, or reorder any `##` section;
    - add, remove, or reorder columns in any Markdown table (the Attendees table is \
    `Name | Role | Company`; the Action Items table is \
    `Action | Owner | Due / Timeframe | Priority`);
    - convert a table to prose or a list, or vice versa.
    If a single cell is wrong or unsupported, replace that cell's content — or blank \
    it — but keep the table shape intact.

    Output ONLY valid JSON (no markdown fences, no commentary) in this shape:
    {
      "edits": [
        {
          "op": "replace",
          "target": "exact substring from the draft to replace",
          "text": "replacement text",
          "reason": "why this change is needed"
        },
        {
          "op": "insert",
          "after_anchor": "exact substring after which to insert",
          "text": "text to insert",
          "reason": "why"
        },
        {
          "op": "delete",
          "target": "exact substring to remove",
          "reason": "why"
        }
      ]
    }

    Rules:
    - `target` / `after_anchor` must match the draft verbatim (copy-paste exact).
    - Prefer small, surgical edits over rewriting whole sections.
    - Do not add decisions, dates, metrics, owners, or commitments that are absent \
    from the transcript.
    - Do not remove a name, title, or company that is present in the contacts \
    rolodex or the supplied attendee list.
    - If the draft is already faithful, return `{ "edits": [] }`.
    """

    static func build(transcript: String,
                      draft: String,
                      contacts: String = "",
                      attendees: String = "",
                      destination: String = "",
                      terminologyBlock: String = "",
                      visionDigest: String? = nil,
                      attachmentCaptions: String = "",
                      instructions: String = defaultInstructions) -> String {
        // `instructions` comes from a free-text Settings editor. Cleared to empty, the prompt
        // would lose the JSON output contract entirely — the backend answers in prose, the
        // parser fails, and the run yields zero hunks with nothing to show for it.
        let head = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultInstructions
            : instructions
        var parts = [head]
        parts.append("""
        CONTACTS ROLODEX:
        \(contacts.isEmpty ? "(no contacts file found)" : contacts)
        """)
        parts.append("""
        SUPPLIED ATTENDEES:
        \(attendees.isEmpty ? "(none provided)" : attendees)
        """)
        if !destination.isEmpty {
            parts.append("""
            Filing location (context only, do not output):
            \(destination)
            """)
        }
        if !terminologyBlock.isEmpty {
            parts.append("""
            Terminology glossary (use these spellings/forms in proposed edits):
            \(terminologyBlock)
            """)
        }
        if !attachmentCaptions.isEmpty {
            parts.append("""
            ATTACHMENTS (filenames and captions):
            \(attachmentCaptions)
            """)
        }
        if let visionDigest, !visionDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("""
            ATTACHMENT VISION (model-analyzed — authoritative for visual content):
            \(visionDigest.trimmingCharacters(in: .whitespacesAndNewlines))
            """)
        }
        parts.append("""
        TRANSCRIPT:
        \(transcript)
        """)
        parts.append("""
        DRAFT SUMMARY:
        \(draft)
        """)
        return parts.joined(separator: "\n\n")
    }
}
