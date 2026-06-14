---
date: 2026-06-13
slug: babysitter-gh-api-field-file-guard
pages: [commands/babysit, modules/babysitter, testing, gaps]
---

Post-commit command/API and executable-stub wiki refresh after commit
`43ebf687` fixed the babysitter dry-run `gh` stub's file-field detector.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. `qmd
search "babysitter gh api file fields guard dry-run stub"` found the existing
[[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]
coverage; targeted search of the configured master wiki path found no relevant
Hive-specific context.

Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`,
`test/unit/babysitter/dry_run_env_test.rb`, and the existing babysitter wiki
pages. The code now normalizes a leading `=` before splitting `-F` field
arguments, so the alternate glued form `-F=q=@secret` is classified like
`-Fq=@secret` and skipped as a local file payload even when `gh api` is
explicitly `--method GET`.

Updated [[commands/babysit]] and [[modules/babysitter]] to document the precise
explicit-GET boundary: scalar query fields may pass through, but `@file` and
`--input` payloads still skip because the GitHub CLI reads local content.
Updated [[testing]] for the new regression example and [[gaps]] to add the
babysitter daemon/stub row to the representative source-coverage map while
carrying the remaining uncertainty: no checked-in artifact proves a full
live-agent `hive babysit --once PROJECT --dry-run` run after this `gh api`
field-file hardening. No wiki page was added or removed, so [[index]] was not
edited. Did not edit compiled [[log]], and did not run `qmd update` or `qmd
embed`.
