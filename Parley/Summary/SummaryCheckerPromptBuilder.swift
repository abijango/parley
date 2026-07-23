import Foundation

/// Builds the checker prompt — must emit JSON edits only.
enum SummaryCheckerPromptBuilder {

    static let defaultInstructions = """
    You are a meticulous meeting-note editor. You receive a transcript and a draft summary \
    produced by another model. Propose precise edits to improve fidelity, completeness, and \
    clarity — without inventing facts not supported by the transcript.

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
    - Do not add decisions, dates, or metrics absent from the transcript.
    - If the draft is already faithful, return `{ "edits": [] }`.
    """

    static func build(transcript: String,
                      draft: String,
                      terminologyBlock: String = "") -> String {
        var parts = [defaultInstructions]
        if !terminologyBlock.isEmpty {
            parts.append("""
            Terminology glossary (use these spellings/forms in proposed edits):
            \(terminologyBlock)
            """)
        }
        parts.append("""
        TRANSCRIPT:
        \(transcript)

        DRAFT SUMMARY:
        \(draft)
        """)
        return parts.joined(separator: "\n\n")
    }
}
