## [2026-06-19T10:21:08Z] maintenance — rebase PR #491 onto current main

**Action:** Rebasing PR #491 onto `origin/main` required combining the PR URL
status/TUI surface with the newer `hive-status` v4 dependency schema. Updated
`schemas/hive-status.v4.json` so the current task contract requires and
describes `pr_url` alongside the v4 dependency fields, while preserving v3 as
the pre-dependency compatibility schema. Also adjusted the TUI task-pane layout
minimum name width so the 69-column single-pane fallback keeps readable task
identity after the fixed PR column is present.

Focused schema, status, bot, TUI, daemon, and changed integration tests were
run after the rebase resolution; the default suite was used to catch and fix
the narrow TUI boundary regression.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[modules/pr]]
- [[testing]]
- [[log]]
