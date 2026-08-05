---
title: Decompose the release-candidate upgrade survivor
type: change
module: release-candidate
created: 2026-08-05
tags: [release-candidate, upgrade, architecture]
---

`HiveReleaseCandidate::UpgradeSurvivor` now coordinates focused channel oracle,
reviewed updater, channel executor, state snapshotter, and phase executor
collaborators. Public constant names, phase order, command/environment
contracts, invariant evidence, channel receipts, teardown, blockers, and output
shape are unchanged. Candidate tool identity now covers every extracted source,
and a focused contract pins clean leaf loading plus source ownership.
