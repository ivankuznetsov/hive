# 2026-11-02 — Per-task review fix-pass grants

- Added operator-only `hive review-grant` for evidenced
  `REVIEW_STALE reason=final_fix_unverified` tasks, including pre-feature
  tasks without a scheduler recovery observation. Each decision grants an
  explicit 1–3 fixes with a bounded secret-scanned reason and grant-specific
  evidence token.
- Persist immutable grant and fixed-completion receipts, retain a private
  append-only task-root audit, reconcile interrupted application before exact
  marker clearing, and derive remaining slots across restarts and ordinary
  commits. Same-cycle parks retain allowance without granting recovery
  authority; completion, generation changes and review resets expire it.
- Resume the existing accepted findings and require free verification after
  the final granted fix. Protect receipt paths and names around agents through the artifact firewall,
  enforce managed-agent denial across adapters, preserve the bound HEAD from
  automatic rebase, and parse pass numbers above 99 numerically.
- Advertise the dedicated operator command and current allowance through the
  required nullable `review_grant` field in operational status v5. Published
  `hive-review-grant.v1`, usage/error contracts and the command owner page.

Pages: [[commands/review-grant]], [[stages/review]], [[modules/daemon]],
[[commands/status]], [[modules/protected_files]], [[cli]].
