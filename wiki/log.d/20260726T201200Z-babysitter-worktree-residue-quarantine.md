---
title: Babysitter quarantines undeletable worktree residue
type: log
tags: [babysitter, worktree, recovery, dogfood, bugfix]
---

# Babysitter quarantines undeletable worktree residue

The current-main dogfood run found Todero PR 46 repeating an opaque
`git worktree add` failure. An earlier container-backed repair had left
root-owned cache files under the babysitter checkout. `git worktree remove
--force` failed, `FileUtils.rm_rf` silently left the residue, and the
babysitter attempted to recreate the checkout at the still-occupied path on
every ten-minute tick.

`Hive::Babysitter::Worktree` now preserves any cleanup residue by atomically
renaming the top-level checkout into the project-local
`.hive-state/babysitter/quarantine/worktrees/` directory. Because the rename
stays on the same state filesystem, child ownership does not prevent recovery.
It then runs `git worktree prune --expire now` before adding the refreshed PR
head. Quarantine and prune failures raise a focused `Hive::WorktreeError`
instead of deferring the same ambiguous add failure to the next tick.

Focused regression coverage simulates undeletable container residue, verifies
its bytes survive in quarantine while the canonical path is cleared, and pins
both fail-closed error paths.
