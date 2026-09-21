---
title: Complete command owner contract validation
date: 2026-09-02
tags: [cli, wiki, commands, regression-guard, ci]
---

- Completed the review-strengthened command-owner guard by keeping validation
  section-bounded and per command while recognizing the repository's existing
  semantic contract headings. Adjacent output, serialization, and exit sections
  can no longer mask a removed required section in the focused fixture.
- Filled the owner-page gaps exposed by the real rendered-help integration,
  including shared `act`, `decide`, stage-action, Screenote, plan-review, and
  worktree owners plus text-only and schema-less command exceptions.
- Focused verification passed: command-index unit 23 runs / 88 assertions and
  real-help integration 1 run / 30 assertions. The change remains limited to
  test support and Wiki documentation; runtime command behavior is unchanged.
