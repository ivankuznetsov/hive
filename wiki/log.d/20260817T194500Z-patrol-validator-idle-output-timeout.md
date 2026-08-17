---
title: Patrol validation gains an idle-output deadline
date: 2026-08-17
tags: [patrol, refactor-patrol, validation, timeout]
---

`Hive::Patrol::Validator` now enforces two independent deadlines per command
run: the existing `timeout_sec.patrol` wall-clock backstop and an optional
`timeout_sec.patrol_idle` idle-output deadline. Reader threads stamp a shared
monotonic pulse on every stdout/stderr chunk; the wait loop kills the process
group as soon as the child has been silent for the idle window, instead of
holding the patrol cycle until the wall-clock cap. `CommandResult` records
which deadline fired in a new `timeout_reason` field (`wall_clock` /
`idle_output`); exit code stays 124 and `passed?` semantics are unchanged, so
fixer fail-closed classification is untouched. Both `Hive::Patrol::Fixer` and
`Hive::RefactorPatrol::Fixer` plumb the new knob. Unset or non-positive
disables the idle deadline (historical behavior). Motivation: on the dogfood
box, full-suite validation held cycles for the entire wall-clock cap when a
child wedged; a progressing suite prints continuously, so a short idle window
fails hangs fast while a generous wall clock stops punishing slow-but-live
runs.
