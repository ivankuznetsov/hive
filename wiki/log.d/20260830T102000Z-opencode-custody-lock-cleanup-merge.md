---
title: Preserve OpenCode custody and child-lock cleanup together
date: 2026-08-30
tags: [opencode, process-custody, locks, merge]
---

Merged current `main` into the OpenCode process-custody branch. `capture_process`
now retains its completion-probe result while also clearing the exact completed
child identity from the task lock, so detached-descendant cleanup and normal
agent lock lifecycle coexist.
