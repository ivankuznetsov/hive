---
title: Pin worktree quota retry metadata
date: 2026-09-09
---

The PR sweep retained the shared spawn-result limit predicate and text selector.
The worktree regression now uses a fixed clock to cover formatted limit errors,
raw provider walls with an empty typed field, and opaque typed limit text with
an explicit reset date. It asserts the selected provider and exact retry time.
Repeated implementation comments were shortened without behavior changes.
