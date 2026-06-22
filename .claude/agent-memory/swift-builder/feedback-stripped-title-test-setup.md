---
name: stripped-title-test-setup
description: strippedTitle bare-company case only triggers when contact.company != nil; test with named company section not ## Other
metadata:
  type: feedback
---

When testing `PersonEditorView.strippedTitle` for the bare-company case (title == company), the contact must be in a named company section (`## Customers\n### Acme`) not under `## Other`. Under `## Other`, the parser sets `contact.company = nil`, so the guard in `strippedTitle` fires early and the bare-company check is never reached.

**Why:** The rolodex parser uses section headers to set `currentCompany`. `## Other` resets company to nil. Only named subsections (e.g. `### Acme` under `## Customers`) produce a non-nil company on the Contact struct.

**How to apply:** Any test that needs to exercise company-aware logic in `strippedTitle`, `upsertPerson`, or `renameContact` must use a rolodex fixture with a named company section. Using `## Other` for such tests silently bypasses the code paths being tested.
