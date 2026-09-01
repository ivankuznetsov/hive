---
title: Accept delivered task ancestors during evidence closure
type: bugfix
source: lib/hive/task_closure.rb, test/unit/task_closure_test.rb
created: 2026-09-01
tags: [closure, worktree, pull-request, squash-merge]
---

Evidence-bound closure now treats a clean task worktree as delivered when its
HEAD is an ancestor of the verified same-repository merged PR head. This covers
review and CI fixes appended to the same PR branch before a squash merge while
preserving the unique-work blocker for unrelated commits and unavailable
ancestry evidence.
