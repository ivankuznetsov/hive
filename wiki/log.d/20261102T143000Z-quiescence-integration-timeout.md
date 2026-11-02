---
title: Allow quiescence integration finalization time on shared CI runners
type: log
created: 2026-11-02
tags: [daemon, quiescence, testing, ci]
---

- Increased the registered-process quiescence integration timeout from one to
  ten seconds. The controller reserves 15% for finalization, so the original
  test allowed only 150 ms for checkpoint and proof I/O after process shutdown.
- Reproduced the CI failure with a 300 ms checkpoint delay: the checkpoint
  completed, but the controller correctly returned `deadline_exhausted`.
- Kept the stopped-process and proof assertions and production deadline logic;
  controlled-clock unit tests continue to verify deadline enforcement.
