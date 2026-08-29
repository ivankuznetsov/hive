---
title: Evidence closure follows each workflow terminal stage
type: change
date: 2026-08-28
tags: [task-closure, workflows, patrol-fix, archive]
---

Evidence-bound task closure now derives its destination from the task's workflow
descriptor instead of coding's global `9-done` archive verb. Coding tasks still
close to `9-done`; workflows such as content and Patrol Fix close to their own
`6-done` terminal stage while retaining the same receipt validation, guarded
move, terminal run, and replay behavior.
