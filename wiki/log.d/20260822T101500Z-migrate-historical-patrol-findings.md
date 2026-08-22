## One-time historical Patrol import covers both discovery engines

- Extended `script/migrate_patrol_findings.rb` to import active ordinary
  findings and accepted Architecture Patrol `fix`/`discuss` dispositions.
- Kept the migration as an explicit local script: no daemon hook, cutover
  policy, legacy runtime reader, action replay, or rollback subsystem.
- Bound target-less legacy findings to the current default branch and redacted
  secret-like source text before task persistence.
- Added dry-run, idempotency, conflict, mixed-route, legacy-revision, and
  redaction coverage.
