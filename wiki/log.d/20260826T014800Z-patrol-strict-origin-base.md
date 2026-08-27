---
title: Anchor Patrol fixes to the exact remote default branch
type: fix
date: 2026-08-26
tags: [patrol-fix, worktree, git, dogfood]
---

First-generation Patrol Fix worktrees now fetch the configured default branch
from `origin` and use that exact OID as their controller-owned base. Inbox's
local `HEAD` remains decision evidence and no longer controls branch ancestry.

The stage fails before agent launch when the remote base cannot be fetched;
there is no local fallback. Same-generation retries and rework keep their
existing generation-bound custody without refetching a moving remote branch.
Regression coverage models a local checkout with an unrelated commit and
proves that the fix worktree contains only the remote base.
