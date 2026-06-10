---
name: edit-curly-quote-hazard
description: The Edit tool injects U+201C/U+201D curly quotes into string literals, causing Swift compiler errors — use Python for exact byte-level replacements
metadata:
  type: feedback
---

When using the Edit tool to replace code blocks that contain ASCII double-quoted strings, the tool sometimes replaces the ASCII `"` (U+0022) with typographic/curly `"` (U+201C) or `"` (U+201D) inside string literal positions. Swift's compiler rejects these with `error: Unicode curly quote found, replace with '"'`.

**Why:** The Edit tool's model uses curly quotes for typographic reasons in its generated text, even inside code blocks. The original file may have mixed regular + curly quotes as part of typographic styling (curly quotes as string CONTENT to display in log messages), which makes the issue subtle.

**How to apply:** After any Edit that replaces lines containing string literals, do a quick scan:
```python
python3 -c "
with open('path/to/file.swift', 'r') as f:
    content = f.read()
for i, line in enumerate(content.split('\n')):
    if '“' in line or '”' in line:
        print(f'Line {i+1}: {repr(line[:100])}')
"
```
If curly quotes appear as STRING DELIMITERS (wrapping the entire string literal), fix them with Python replacing the specific curly-quoted substrings with ASCII-quoted versions. The Edit tool cannot safely fix itself — use Python `str.replace()` with the exact Unicode characters.

Note: Curly quotes INSIDE a string literal body (as content) are intentional in this codebase (log messages use typographic `"title"` style) and should be left alone.
