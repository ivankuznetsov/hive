---
title: Strengthen E2E run diagnostic regression proof
date: 2026-11-03
tags: [e2e, testing, review]
pages: [e2e, gaps]
---

Binary regressions now compare debug stderr with a captured outer exception
backtrace, including legitimate repeated frames, while a distinct existing
cause remains absent. The fixture overrides Runner only in a child process;
production dispatch and formatting remain exercised through bin/hive-e2e.
Filesystem-failure checks identify reporting frames structurally, expected
human errors must contain only their first message line and no frames, and
repeated attempts verify the scratch directory contains only the unchanged
blocker. The clean usage-error fixture uses isolated run storage, unexpected
failure scenarios have unique names, and redundant checks were removed.

The E2E documentation now scopes best-effort crashed reporting to
Runner#run_all; signal handling remains outside that contract. The shared
emitter documents its existing String-or-Exception input contract.

Validation: the focused binary and Runner files pass together (88 tests,
1,685 assertions), and the three changed Ruby files pass RuboCop. Temporarily
rendering the cause backtrace makes the new binary regression fail; the
production formatter was restored before the passing run.

Pass-2 review verification of the pass-1 tree reported passing binary tests
(74 tests / 1,589 assertions), Runner tests (14 tests / 96 assertions), and
`bundle exec rake e2e:lib_test` (229 tests / 2,374 assertions). These figures
come from the reviewer's reruns and supplement the focused validation above;
the `20261103T040000Z` fragment retains the earlier implementation-run evidence.
