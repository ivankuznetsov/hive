---
title: Patrol recovers interrupted local fix attempts without daemon failure
type: fix
created: 2026-08-16
tags: [patrol, occurrence-journal, recovery, daemon, worktree]
---

Ordinary Patrol now settles a process-interrupted local fix attempt before the
cycle continues. It adopts an exact patch receipt when one already exists; if
none exists, it records a failed `interrupted_fix_attempt` only after proving
the deterministic Patrol worktree is clean, correctly registered, and already
contained in the freshly resolved default branch. Dirty, mismatched, broken,
or uniquely committed work remains untouched for operator recovery. Patch JSON
is stored as the outer attempt's subordinate result rather than creating a
nested effect. Retirement uses non-force checkout removal and deletes the
branch only under an expected-head lease, so work added after the proof survives.
Ancestry checks and branch retirement stay behind `GitOps`, which validates the
Git arguments and owns the compare-and-swap ref deletion.

The daemon scheduler also tests the occurrence's complete effect set before
strict finalization. An unresolved effect keeps the occurrence recovery-active
and emits a blocked diagnostic instead of raising through the whole daemon
tick. Regression coverage includes exact-patch adoption, safe clean-checkout
retirement, residue preservation, broken registration, and nonterminal
scheduler recovery.
