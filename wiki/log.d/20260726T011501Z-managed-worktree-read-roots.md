---
title: Expose managed worktrees as portable read roots
date: 2026-07-26
---

**Changed:** Managed Codex and Grok worktree actors now retain the
controller-trusted `base_add_dirs` supplied by the stage. Codex adds those
directories to its named read-only filesystem policy, while Grok mounts them
read-only through bubblewrap, so both providers can inspect the repository
checkout used as their working directory.

**Safety:** Trusted caller roots must resolve to existing directories or policy
compilation fails closed. They affect only provider read visibility; Hive still
authorizes and materializes host outputs exclusively beneath the task folder
through path-qualified `Edit(...)` rules.

**Verified:** Focused Codex, Grok, and managed-worktree policy tests plus
RuboCop on the touched implementation and test files.
