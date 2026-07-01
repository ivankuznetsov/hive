# diagnose evidence fallback

**Action:** Added `Hive::DiagnosticEvidence` as the shared no-empty fallback for
`hive status --diagnose` and Telegram Refresh diagnosis. When
`TaskAction#diagnostic` is nil but a task folder still has
`diagnostics/red-status.md`, logs, or a marker, the CLI and bot now surface a
one-line summary plus the source path instead of the bare
`No diagnostic available for <slug>.` string.

**Coverage:** Added focused resolver tests for red-status frontmatter/body,
newest-log selection, marker-only fallback, secret redaction, truncation,
invalid UTF-8 tails, and a marker/synthetic-summary sweep covering red markers,
stale-agent, plan/finalize synthetic cases, and green-rotated logs. Updated
bot, status diagnose, status text-branch, and schema tests for the evidence
fallback and `marker_summary` diagnose envelope field.

**Docs:** Refreshed [[commands/status]] for the read-only diagnose evidence
fallback and the `hive-status-diagnose` `marker_summary` field.
