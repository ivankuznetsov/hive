---
title: Refactor patrol evidence normalization
date: 2026-07-04T10:00:00Z
tags: [command, refactor-patrol, decision]
---

Dogfood-driven polish on [[commands/refactor-patrol]]: the first real run
returned 0 accepted theses because the agent emitted file-anchored evidence in
a shape the admissibility gate didn't recognize (`files` array + `claim` prose,
named signal without a `value`, `refactor` instead of `proposed_refactor`).

- **The review prompt now teaches the contract by example.** A full worked
  thesis (with the exact evidence item shape) replaces the bare
  `{"theses": []}` skeleton, and the rules spell out singular `file` and
  the required measured `value`.
- **The reviewer normalizes honestly recoverable drift.** A plural
  `files`/`paths` array expands to one evidence item per path; file-less
  evidence whose text literally names an owned file is anchored to it (never
  invented); a measurable signal missing `value` is backfilled from the
  feature's own measured leverage signals; `refactor`,
  `characterization_notes`, and object-shaped `feature` aliases map to their
  schema fields. Evidence that stays path-less remains flagged inadmissible.
- Replaying the captured dogfood `theses.json` through the fixed reviewer
  accepts all 3 theses (previously 0).
