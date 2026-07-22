---
title: Worthy patrol finding remediation
date: 2026-07-22
tags: [patrol, attempts, cli, babysitter, installer, e2e]
---

- Durable attempts now accept authenticated launching handoffs, preserve
  predecessor outputs when a successor supplies no replacement, and drain
  final frames after terminal/lost receipts. Display-name generation also
  accumulates structured streaming text, Pi authentication honors
  `PI_CODING_AGENT_DIR`, and dependent Codex package operations recognize the
  config snapshot created by their prerequisite.
- Install/lifecycle paths now keep rollback armed through staged launcher
  construction and activation, restoring the exact previous `hive`, `hv`, and
  RubyGems shim bytes and modes after gem, write, chmod, or swap failures;
  uninstall Hive Web with the daemon and bot, restore the
  original hive-bench checkout after submission attempts, normalize legacy
  babysitter state paths, and avoid spending fork metadata calls for already
  green PRs. Bench submission output now reports a repository-relative corpus
  locator with the exact submission ref and commit SHA, rather than an absolute
  path that disappears when the caller's checkout is restored. Its tests use a
  real local push to a bare fixture while keeping `gh` and external GitHub
  stubbed. The runtime gem explicitly declares `base64 >= 0.2`.
- The main CLI and E2E harness share one JSON-option grammar. E2E version/help,
  scenario dispatch, retention diagnostics, artifact paths, and schema
  contracts are truthful; cleanup environment defaults are now namespaced,
  while legacy generic retention variables remain a warning-backed fallback
  that cannot override their namespaced replacements. Optional `asciinema`
  failures degrade cast capture instead of becoming config errors. Generic
  usage failures use `Hive::UsageError`, while `Hive::InvalidTaskPath` remains
  where the public `invalid_task_path` contract requires it.
  `hive-eval` documents repository-relative paths and exits 127 when Bundler
  cannot be launched, while `hv` accepts semantic prerelease/build versions
  and explains invalid candidates.
- Babysitter dry-run launchers and stubs share one environment-scrubbing
  definition, invoke the Ruby GitHub stub directly, preserve binary argv in
  denied-command logging, and use shared skip-message/artifact helpers. Test
  fixtures and acceptance seams were consolidated without weakening the
  default-deny boundary.
- Ordinary patrol findings now carry an exact target SHA, configured
  validation key, and explicit active/resolved/rejected/superseded lifecycle.
  A registry reconciles old records with PR/dismissal outcomes and performs
  all-history semantic deduplication before persistence. Shipping cycles reuse
  same-target active findings after dry runs or transient fixer failures,
  while matching evidence on a newer target starts a recurrence lineage
  instead of being suppressed forever by an older terminal record. PR and
  dismissal ledgers now carry the target SHA so only the matching lineage is
  dispositioned. Fix attempts reject a stale target and require a clean,
  passing configured baseline before an agent starts; fixer proof must use the
  reviewer-selected validation key.
  These additions publish as `hive-patrol.v3` and
  `hive-patrol-finding.v3`; the previously published v2 files remain byte-for-
  byte compatible with their original contracts.
- The sample systemd daemon unit no longer orders itself after the same
  `default.target` that wants it, avoiding an ordering cycle.
- Hive Web uninstall now derives service identity with an inert installer
  config, so malformed global web settings cannot abort unit deregistration;
  Linux and macOS service-manager failures continue through later cleanup.
- The quality pass centralized validation-key discovery and structured-message
  accumulation, bounded streamed message memory without exposing a truncated
  structured prefix as a complete agent handoff, indexed semantic finding
  history, eliminated repeated lifecycle reads/timestamps and Codex config
  snapshots, reused GitOps default-branch discovery and shared dry-run env
  scrubbing, and removed dead CLI/test aliases without weakening safety gates.
