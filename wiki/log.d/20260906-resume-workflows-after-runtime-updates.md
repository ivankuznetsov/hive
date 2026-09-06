---
title: Resume workflows after runtime updates and legacy base metadata gaps
date: 2026-09-06
---

Managed workflows no longer require installation-time profile fingerprints to
match current executable and adapter metadata. The owner-selected agent, model,
effort, slot contract, and package identity remain authoritative. Current runner
capability validation still runs before launch; configuration updates use the
same rule instead of demanding an unchanged executable path.

Legacy artifact worktree pointers can omit base_oid/base_branch. Without a
saved PR handoff, the shared Git comparison-base resolver already determines
the actual evidence range; old metadata is no longer a prerequisite for that
calculation. Contradictions, invalid saved bases, dirty worktrees, and empty
implementation ranges remain rejected.

Regression tests cover both runtime and workflow-update paths, plus real Git
worktrees with legacy pointers. A read-only live check resolved the previously
blocked Hive-site task to its actual 14 changed files.
