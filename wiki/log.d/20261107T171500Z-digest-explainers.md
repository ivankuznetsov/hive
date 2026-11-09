## 2026-11-07 — Digest becomes an explainer briefing with diagrams

- Hive now owns the digest prompt (`DailyDigest::DocumentPrompt`) instead of
  PRDigest's short 250–400-word editorial prompt, which forbade explaining
  mechanisms. The new prompt targets an owner who reads the digest instead of
  PRs: brief, `Needs you`, per-repository outcome sections with before/now/how,
  and Mermaid diagrams where a flow changed.
- Web renders ```mermaid blocks with vendored mermaid.js (strict, no HTML
  labels, image/link nodes stripped); Telegram links to the web digest instead.
- Fixed duplicated repository stats when a document split one repository
  across several `##` sections.
- Requires prdigest `~> 0.4.1` (GitHub rate-limit retries wait past the reset).
- Pages: [[modules/daily-digest]].
