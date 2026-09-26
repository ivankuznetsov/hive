---
date: 2026-09-26
title: Preserve complete one-shot command inventories
tags: [babysitter, one-shot, scheduling, component-boundaries]
---

- `hive babysit --once --all` now retains malformed registry rows as typed
  per-project configuration errors. A truncated inventory can no longer produce
  a vacuous host-safe result, and single-project adapter construction or call
  failures still emit exactly one shared one-shot document.
- The four one-shot command boundaries now share one usage-contract declaration
  helper while preserving the ordinary Patrol and Architecture Patrol fallback
  envelopes.
- The component-boundary narrative now includes the one-shot project-liveness
  Attempts consumer already declared by the code and YAML inventories.
- `hive daemon clear-hold PROJECT [SLUG]` provides the operator recovery path
  for restart-safe dropped-project and quarantine holds. It clears only the
  named state and requires the daemon to be stopped before editing its durable
  checkpoint.
