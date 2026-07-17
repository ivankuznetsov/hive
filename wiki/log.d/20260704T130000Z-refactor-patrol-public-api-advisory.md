---
title: Refactor patrol public-API advisory semantics
date: 2026-07-04T13:00:00Z
tags: [command, refactor-patrol, decision]
---

Dogfood follow-up on [[commands/refactor-patrol]]: every thesis in a
`bin/`-owned slice was flagged `public_api_impact` and never counted as
accepted, because the caps heuristic conflated *working inside files that
host public surface* with *changing the public contract*. Refactoring
preserves the contract by definition — if it changes the public API it is
not a refactor.

- Path-heuristic matches (`bin/`, `cli.rb`, `schemas/`, routes, docs) are now
  a non-blocking `touches_public_api_surface` advisory in the new
  `risk.advisories` array; `public_api_details` still lists the surface files.
- Only agent-declared `risk.public_api_impact: true` (an admitted contract
  change) still flags `public_api_impact` and blocks acceptance —
  flag-not-drop keeps it visible as out-of-contract.
- Ranked envelope items carry `advisories` (required in
  `hive-refactor-patrol.v1`); the thesis schema's `Risk` gains an optional
  `advisories` array; the text report appends `advisories=` when present.
- The review prompt states the definition: the public contract must behave
  identically post-refactor; proposals that cannot avoid changing it must
  declare it and are reported, not accepted.

Live dogfood dry-run went from `accepted: 0` (both theses flagged
`public_api_impact`) to `accepted: 2` with the advisory visible.
