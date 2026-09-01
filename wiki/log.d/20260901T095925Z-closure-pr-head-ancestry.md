---
title: Accept delivered task ancestors during evidence closure
type: bugfix
source: lib/hive/task_closure.rb, test/unit/task_closure_test.rb, test/fixtures/runtime_control_plane/affected_production.yml
created: 2026-09-01
tags: [closure, worktree, pull-request, squash-merge]
---

Evidence-bound closure now treats a clean task worktree as delivered when its
HEAD is an ancestor of the verified same-repository merged PR head. This covers
review and CI fixes appended to the same PR branch before a squash merge while
preserving the unique-work blocker for unrelated commits and unavailable
ancestry evidence. The runtime control-plane deletion inventory now includes
the 14 production lines added by this validation while remaining comfortably
below its required shrinkage ceiling.
