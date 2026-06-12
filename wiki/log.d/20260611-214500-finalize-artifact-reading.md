---
date: 2026-06-11
slug: finalize-artifact-reading
pages: [commands/web]
---

Task-page reading order and rendering, operator-requested: artifact order
is stage-aware (chronological while working; artifact.md first — and
therefore open — from 8-finalize/9-done, where the deliverable is what the
page is opened for), the log moved below the artifacts as an appendix, and
.md artifacts render as real markdown via redcarpet (GFM tables/fenced
code, autolink, strikethrough). LLM-authored content gets two safety
layers: escape_html turns raw HTML into visible text (markers like
<!-- WAITING --> stay legible), and Rails sanitize with an explicit
tag/attribute allowlist strips what survives. Leading YAML front matter is
dropped from the rendered body. Integration tests pin the finalize/early
ordering, the Artifacts-before-Log layout, and the sanitized rendering.
