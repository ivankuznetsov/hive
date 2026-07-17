# 2026-07-12 — Architecture patrol review fixes

- Hardened read-only discovery with Claude's verified `--safe-mode`
  capability, confined mapper/leverage reads to regular files beneath the real
  project root, and capped each source read at 256 KiB. A reviewer that mutates
  tracked checkout content now fails the command, releases its claim, and
  checkpoints no findings.
- Tightened publication and recovery: OPEN draft PRs no longer reconcile as
  successful publications, and canonical proof rebuilds accept mandatory handoff tasks that have
  legitimately advanced from `6-review` through `9-done` while rejecting other
  or nested paths.
- Made candidate ownership evaluation tick-scoped for bounded repeated work
  while retaining fresh reservation/effect-time checks, and centralized
  architecture state/handoff directory durability through
  `Hive::AtomicFile.fsync_directory`.
- Added mode-aware v1/v2 wrapper usage-error envelopes, corrected init help and
  CLI references to the current `hive-init.v2` producer, and pinned init help to
  the schema-version registry so the advertised contract cannot drift.
- Refreshed architecture-patrol, daemon, agent-profile, GitHub, state, and test
  wiki coverage for these reviewed boundaries. Auto-fixing and issue filing
  remain separate default-off gates from default-recommended discovery.
