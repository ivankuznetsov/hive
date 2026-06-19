---
date: 2026-06-19
slug: digest-redesign
pages: [commands/digest, modules/digest, modules/gh]
---

Redesigned the daily shipped digest layout (operator request). The message now
leads with a brand header `*Hive* #Digest` and a human date (`Fri, 19 June
2026`), an italic `_Summary_` block, **per-project** sections (`*Hive*`,
`*Screenote*`, …) each with `Features`/`Fixes`/`Patrol` subsections, and a
global footer under a divider: `Lines +A/-D · PRs P · Commits C`.

Changes:

- `Hive::Digest::Categories` labels are now `Features`/`Fixes`/`Patrol` (were
  `New features`/`Fixes`/`Patrol tasks`).
- `templates/digest_prompt.md.erb` now asks the model for a top-level one-line
  `summary` alongside the per-item rows; the JSON shape is
  `{"summary": "...", "items": [...]}`. `Digest::Categorizer#categorize` returns
  a new `Digest::Output(by_project:, summary:)` (items mapping kept its old
  `{project => [CategorizedItem]}` shape via `map_output_file`/`map_document`);
  a missing/blank summary falls back to a neutral count.
- New `Hive::Digest::Stats#for_items` aggregates per-PR additions/deletions/
  commits into `Totals`, fetched via the new `Hive::Gh.pr_stats(pr_url)` (keyed
  off the PR URL, so no worktree/chdir is needed). A per-PR `gh` failure is
  logged and skipped, and the renderer omits Lines/Commits when nothing could
  be measured — the digest never fails for want of footer numbers.
- `Digest::Renderer.render` takes `(by_project, date:, summary:, totals:)`;
  project headers are first-letter capitalized for display. All dynamic text
  stays MarkdownV2-escaped (the hashtag's `#` is escaped but left outside the
  bold span so Telegram still tags it).

Verified with a real `hive digest --dry-run --date 2026-06-18`: header, date,
LLM summary, the `*Hive*` / `_Patrol_` section, and a live-`gh` footer
(`Lines +355/-64 · PRs 4 · Commits 11`) all rendered correctly. Refreshed
[[commands/digest]] and [[modules/digest]]; `Hive::Gh.pr_stats` noted in
[[modules/gh]].
