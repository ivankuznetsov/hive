---
date: 2026-08-31
slug: cutover-task-authority-scope
tags: [runtime-control-plane, cutover, babysitter, migration]
---

# Keep disposable babysitter worktrees outside cutover task authority

The fleet cutover now fingerprints each registered project's canonical
`.hive-state/stages/` tree instead of the complete `.hive-state` root. This
retains the fail-closed digest over every task file while avoiding
project-local babysitter worktrees, whose checked-out dependencies may contain
ordinary symlinks and are not imported into the runtime control plane.

Focused coverage proves a babysitter worktree symlink is ignored while unsafe
entries inside a task still stop activation.
