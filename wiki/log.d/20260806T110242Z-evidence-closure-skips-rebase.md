---
title: Skip obsolete branch replay during evidence closure
type: fix
module: task-closure
created: 2026-08-06
tags: [archive, closure, rebase, dogfood]
---

Receipt-backed `already_delivered` and `superseded` archive transitions now run
the terminal Done stage with auto-rebase disabled, including restart resume.
Immutable delivery evidence has already settled the branch outcome and Done
only records the terminal marker and cleanup instructions, so closure no longer
launches conflict-resolution agents against obsolete task history. Ordinary
workflow runs and ordinary archive transitions retain their existing rebase
behavior.
