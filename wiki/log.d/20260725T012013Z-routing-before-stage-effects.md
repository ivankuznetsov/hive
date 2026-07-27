---
date: 2026-07-25
summary: Validate effective implementation routing before stage effects
---

- Moved execute identity resolution ahead of reviews-directory, worktree,
  pointer, and task-marker initialization for both first and continuation
  passes.
- Moved review-fix identity resolution ahead of the working marker, phase
  event, Git status preparation, and pre-fix residue auto-commit.
- Preserved the prior review marker and worktree state when effective routed
  controls are unsupported.
