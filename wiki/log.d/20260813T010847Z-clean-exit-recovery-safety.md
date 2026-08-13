---
title: CleanExit residue safety, recovery, and operator evidence
area: stages
date: 2026-08-13
---

**Action:** Hardened every CleanExit auto-commit with staged-symlink rejection
and a bounded exact-staged-blob secret scan, while retaining `git add -A` plus the documented
strict-`.gitignore` contract. Tracked-file scans subtract identical secret matches
already present at `HEAD`, so unrelated edits to detector fixtures remain recoverable
while new or changed matches are still rejected. Added `hive worktree status`,
`commit-residue`, `discard-residue`, and `repair --strategy` as task-locked,
owned-worktree recovery verbs. They never clear the durable marker; agents
must refresh status and use the current generation-guarded retry.

Successful residue commits now carry bounded structured event metadata.
`hive status --json` publishes the current invocation's `auto_residue` summary
and the resolved `config_summary.stages.ensure_clean_on_exit` value. The TUI
renders `auto-residue:N`, and Telegram emits a deduped, keyboard-free FYI even
when ordinary ready/input notifications are suppressed. Finalize's entry
backstop emits the same event in addition to its dated log.

**Evidence:** Focused CleanExit, worktree-command, status/schema, TUI, bot, and
event tests cover safety rejection, exact-path discard, marker preservation,
consumer mapping, notification suppression exceptions, and legacy-event
compatibility. Independent review additionally pinned Git pathspec-magic
filenames, binary secret blobs, literal-path discard, lossless marker path
encoding, secret-shaped filename rejection and notification redaction, JSON
usage errors, and the canonical recovery-skill route.
