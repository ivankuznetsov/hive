---
title: Run independent Hive web CI suites in parallel
slug: parallel-web-ci
date: 2026-08-14T16:24:00Z
---

**Action:** Split the hosted Hive web job into three independent matrix cells:
Rails integration tests plus lint, Playwright system tests, and the Playwright
golden-path E2E. The browser payload is installed only for the two cells that
use it, and the root bundle is installed only for the golden-path daemon test.
The exact existing `Hive web (Rails tests + system)` check name remains as a
fail-closed aggregate over all three cells, preserving its branch-protection
contract.

**Measurement:** The exact-head iteration-one run completed the serial Hive
web job in 441 seconds. Its two longest steps were system tests at 184 seconds
and integration tests at 149 seconds; the remaining golden-path setup and test
steps took 92 seconds. Hosted timing of the parallel matrix is required before
accepting this iteration.
