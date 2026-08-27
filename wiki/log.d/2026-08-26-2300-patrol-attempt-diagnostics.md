---
date: 2026-08-26
title: Patrol Fix attempts retain typed private diagnostics
tags: [patrol-fix, attempts, diagnostics, status, security]
---

- Managed Patrol agents now normalize process, provider, parser, and Artifact
  Firewall failure facts into one bounded, versioned diagnostic frame.
- The Attempts supervisor validates or synthesizes the diagnostic, rejects
  secret-bearing metadata, injects the exact private log reference, and
  appends the immutable output reference before the terminal receipt. Trusted
  provider evidence owns attribution when present.
- Task and operational status verify the receipt-bound artifact and project
  the same safe typed fields, digest, owner, and references without reading raw
  provider output or raw logs.
- Status point-fetches that artifact only after the journal identifies the
  current attempt as terminal and failed or cancelled. Invalid Fix reports
  retain the specific `fix_report_invalid` cohort code.
- Workflow classification resolves the task controller rather than inferring
  it from overlapping stage directory names. Patrol controller exceptions
  preserve semantic worktree, validation, publication-policy, and state-Git
  failure cohorts before they reach the supervisor.
