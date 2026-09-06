## Betterleaks and publication-range cleanup

- Replace Hive-owned credential detection and password classification with
  bundled, pinned Betterleaks; retain diagnostic redaction separately.
- Remove the additional authoring-lint regex/entropy detector and benchmark
  scanner subprocess; both now use the same Betterleaks adapter.
- Build release gems with checksum-verified Linux/macOS x64/arm64 binaries.
  Scanner errors fail closed and raw findings never enter task diagnostics.
- Remove publication, Patrol diff, auto-commit blob, repair-history, and
  outcome-evidence diff size gates. Hash publication patches incrementally.
- Calculate ordinary publication and outcome-evidence ranges from the intended
  PR base's merge-base, preserving creation provenance and frozen review receipts.
- Accept legacy publication pointers without a creation OID by binding the
  initial request to a verified Git merge-base, without editing task metadata;
  subsequent requests retain the controller's recorded creation base.
- Add regression coverage for rebased old tasks, large clean changes,
  intermediate and binary secrets, scanner failures, and ignored agent policy.
- Preserve existing diagnostic redaction-version metadata and reject extra
  bytes observed during append-only diff replay, including concurrent growth.
- Reconcile owned PRs when the comparison base advances, including an empty
  range after merge, without replacing the original publication ownership proof.
