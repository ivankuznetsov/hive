---
title: Test runtime boundaries instead of pinning refactor line counts
type: change
date: 2026-09-05
---

Removed the historical 20-percent deletion calculation, exact per-file source
lengths, and Git-history inspection from the runtime deletion test. An ordinary
baseline-persistence simplification reproduced its failure solely by changing
the recorded net line count, without violating a runtime boundary.

The behavioral guards remain: retired sources, schemas, constants and environment
inputs stay absent; retained authorities stay present; clean bootstrap creates
only current runtime storage. The fixture retains the unchanged legacy writer
and path-override lists consumed by the real old-writer upgrade/fencing test.
