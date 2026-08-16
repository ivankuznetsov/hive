---
title: Keep bound brainstorm answers available without execution checkpoints
date: 2026-08-16
---

Hive Web now treats exact, binding-backed brainstorm questions as their own
mutation boundary. A fresh waiting task can accept answers even when its
task-workspace projection is partial because a legacy projection checkpoint,
current attempt, or resource record is missing. `Hive::Commands::Answer` still
revalidates every opaque binding at write time, while Approve, Retry, Run, and
other execution-dependent controls retain the stricter workspace-evidence gate.

Focused unit, Rails integration, and Playwright regression coverage exercises
the checkpoint-less task path, preserves typed input across pushed morphs for
the same binding, and rejects free-form drafts after a question-round change.
