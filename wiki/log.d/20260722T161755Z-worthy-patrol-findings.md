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
- Install/lifecycle paths now restore a previous managed wrapper when upgrade
  installation fails, uninstall Hive Web with the daemon and bot, restore the
  original hive-bench checkout after submission attempts, normalize legacy
  babysitter state paths, and avoid spending fork metadata calls for already
  green PRs. The runtime gem explicitly declares `base64`.
- The main CLI and E2E harness share one JSON-option grammar. E2E version/help,
  scenario dispatch, retention diagnostics, artifact paths, and schema
  contracts are truthful; cleanup environment defaults are now namespaced.
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
  all-history semantic deduplication before persistence. Fix attempts reject a
  stale target and require a clean, passing configured baseline before an
  agent starts; fixer proof must use the reviewer-selected validation key.
- The sample systemd daemon unit no longer orders itself after the same
  `default.target` that wants it, avoiding an ordering cycle.
