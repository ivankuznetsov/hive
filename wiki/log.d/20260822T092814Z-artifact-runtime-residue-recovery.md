---
title: Artifact runtime residue recovers without product commits
date: 2026-08-22
tags: [artifacts, daemon, recovery, pi, dogfood]
---

Live Pi evidence production exposed the upgrade edge after project commands had
written Rails runtime blobs through the retired direct `storage/` bind. The
replacement overlay prevents future source writes, but the existing untracked
bytes made every automatic `7-artifacts` retry fail its clean identity preflight.

`Hive::Artifacts::RuntimeResidueRecovery` now gives the daemon a narrow,
recoverable bridge. Under the task lock and only for the exact
`outcome_evidence_invalid` / `implementation worktree must be clean` marker, it
accepts exclusively untracked regular files below the three runtime directories
managed by `ProjectCommandSandbox`, journals their size/mode/SHA-256, and renames
them into the task's owner-private outcome-evidence quarantine. It refuses
tracked or staged edits, symlinks, special files, unrelated paths, conflicts,
and bounded-size violations. The bytes are neither deleted nor committed into
the product, and the ordinary daemon recovery lifecycle owns the subsequent
retry.

Focused service and recovery-coordinator tests cover successful quarantine,
clean Git state, preserved tracked files, refusal classes, non-artifact no-op,
daemon ordering, and fail-closed queue admission.
