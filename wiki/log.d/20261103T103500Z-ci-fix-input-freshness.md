---
title: Preserve unanswered input without scheduler recovery evidence
---

- Scope scheduler freshness precedence to recovery or completed input. Ordinary
  unanswered questions remain answerable when scheduler status is unavailable
  or workspace history is partial.
- Verify both previously failing Chromium Q&A morph tests and the real
  `watch_semantic_transitions` subprocess scenario.
- Extend focused tests across failed-edit admission, lock contention, source
  invalidation, terminal receipt replay, provider failure details, bounded stage
  result transport, and unavailable status storage to cover CI-reported gaps.
- Validation: 444 focused tests, both failing browser tests, the watch scenario,
  and RuboCop pass. Instrumented focused tests exercise all 47 lines reported
  uncovered by CI; the runner retains the full exact-head CI checkpoint.
