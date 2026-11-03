---
title: Harden E2E diagnostic test failure reporting
date: 2026-11-03
tags: [e2e, testing, review]
pages: [e2e, gaps]
---

The binary tests assert the human diagnostic prefix before extracting its
first line, so empty stderr produces an assertion failure. Each child attempt
clears its exception evidence and must create a fresh file before it is read.
The exact-value debug test now names the activation condition it checks.
Ordinary scenario failures retain human and JSON checks with debug enabled,
while two redundant sandbox executions with debug unset were removed; the
success baseline remains covered.

[[gaps]] now records that the missing-scenario fixture temporarily makes the
shared scenario tree unreadable to concurrent catalog readers. The pass-1 log
fragment now includes the reviewer's refreshed binary, Runner, and harness-wide
verification figures, preserving the historical implementation-run records.

Pass-2 validation: `bin/test test/e2e/lib/hive_e2e_binary_test.rb
test/e2e/lib/runner_test.rb` passed 88 tests / 1,726 assertions with no failures,
errors, or skips. `bundle exec rake e2e:lib_test` passed 229 tests / 2,415
assertions with no failures, errors, or skips. RuboCop passed for the changed
binary test file.
