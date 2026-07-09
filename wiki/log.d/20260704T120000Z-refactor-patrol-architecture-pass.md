---
title: Refactor patrol architecture pass
date: 2026-07-04T12:00:00Z
tags: [command, refactor-patrol, architecture]
---

Two-step architecture pass on [[commands/refactor-patrol]] (behavior
unchanged, each step live-tested with a real-agent dry run):

- **`ThesisNormalizer`** — raw-thesis normalization (alias/evidence repair),
  admissibility, and behavior-preservation guidance moved out of `Reviewer`
  into a pure class (no I/O, no agent coupling) returning a `Thesis` or an
  `Invalid` carrying schema errors. This is the fastest-evolving policy
  surface, now unit-tested directly.
- **`ReviewAgentRunner`** — the production agent spawn + usage recording
  extracted from `Reviewer`; the `agent_runner:` call protocol is now the
  only seam. `Reviewer` is pure per-feature orchestration (~130 lines).
- **`Commands::RefactorPatrol#run_cycle`** decomposed into named stages:
  `resolve_project!` → `scoped_features` → `score_features` →
  `guard_theses` → `build_payload`, with the module-wide
  `(project_root, cfg, state)` argument convention.
- Thesis test fixtures deduplicated into `test/unit/refactor_patrol/
  thesis_fixtures.rb` shared by reviewer/normalizer tests.
