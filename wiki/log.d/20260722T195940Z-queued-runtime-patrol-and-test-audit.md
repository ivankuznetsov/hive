---
title: Audit queued runtime, patrol, dependency, and focused-test commits
date: 2026-07-22T19:59:40Z
tags: [wiki, attempts, patrol, babysitter, dependencies, bot, web, e2e]
---

Inspected all ten queued commits and every changed-path blob with direct
`git show`. The supplied path list for `176b5053` is stale: the immutable
commit is the 18-file lifecycle/install/config change, not the listed
CLI/E2E/schema snapshot. Patch comparison also establishes that `e1f431a4`,
`3cea9e79`, `3af0766e`/`fb4a1a9b`, and `8d582712` are rebased or
cherry-picked equivalents of the already documented `5c1a20e9`, `9c4b4d69`,
`2f25207c`, and `05784893` patrol/runtime series. `176b5053` carries the same
operations change as `01e85c89` on a different base.

Existing [[modules/attempts]], [[modules/agent]], [[modules/agent_profile]],
[[commands/babysit]], [[modules/babysitter]], [[commands/bench-submit]],
[[commands/uninstall]], [[commands/patrol]], [[modules/patrol]], [[e2e]],
[[operating]], and [[testing]] already cover the final handoff, installer,
dry-run, finding-registry, schema-v3, E2E retention/artifact, and submission
contracts. Corrected three residual drifts: [[dependencies]] now distinguishes
the current eleven direct runtime gems from the queued twelve-gem Base64 line
and records `708fd959`'s Rails lockfile sync; [[modules/bot]] now describes the
current immediate durable-admission and unclaimed-delivery cleanup path proven
by `c0c6c147`; and [[testing]]
records `d28377b2`'s durable PR-gate browser wait instead of the transient
execute badge. [[gaps]] records commit equivalence, branch-only provenance,
the stale manifest, and the remaining current-main/hosted evidence boundary.

None of the supplied SHAs is an ancestor of the refresh branch. Page coverage
remains 94, so [[index]] did not change. Compiled [[log]] was not edited, and
QMD was intentionally not run.

**Refreshed pages:**

- [[dependencies]]
- [[modules/bot]]
- [[testing]]
- [[gaps]]
- [[log]]
