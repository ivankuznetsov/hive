---
title: Fix capture runtime discovery and retire lockfile-only approval stops
date: 2026-09-06
---

- Codex evidence capture reuses managed executable provenance rather than
  admitting an unrelated native binary from PATH. Live Hive-site and Webmail
  producer logs showed sandbox exec failures for the npm vendor binary before
  returning empty evidence. The evidence schema remains strict.
- Lockfile changes no longer trigger the default fix guardrail. Existing
  lockfile-only findings no longer require checkboxes on review resume, while
  match counts, HEAD binding, clean worktrees, other findings, and explicit
  project rules retain their existing checks.
- Added regression tests for competing Codex installations, lockfile changes,
  and existing waits with mixed findings or a custom lockfile rule.
