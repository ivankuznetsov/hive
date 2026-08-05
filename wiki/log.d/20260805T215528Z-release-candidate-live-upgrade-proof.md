---
title: Repair first live 0.7.0 upgrade proof
type: fix
module: release-candidate
created: 2026-08-05
tags: [release-candidate, upgrade, invariants, channel]
---

The first full 0.7.0 candidate campaign exercised the real upgrade survivor
and exposed two deterministic harness defects. Semantic snapshots now ignore
elapsed task age, candidate-owned managed-skill expectations, and newly added
empty status defaults while continuing to reject observed Doctor changes and
non-empty user state. The reviewed channel updater now uses a dedicated empty
`HIVE_HOME`, preventing the representative phase's channel marker from
shadowing the simulated install prefix during `hive update`.

Focused regressions cover both boundaries. This repair does not itself provide
trusted candidate evidence or perform a release action; a fresh exact-main
hosted campaign is still required.
