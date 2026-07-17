---
title: Wrapper option scans respect the end-of-options delimiter
type: log
created: 2026-07-15
tags: [cli, e2e, argv, json, help]
---

**Action:** Fixed `bin/hive` and `bin/hive-e2e` wrapper preprocessing so the
first explicit `--` ends wrapper-owned help and JSON option scans. Tokens after
the delimiter now remain literal arguments, including `--help`, JSON booleans,
and unsupported `--json=VALUE` assignments. Both wrappers snapshot argv before
rewrites and Thor dispatch, and wrapper-owned error formatting derives JSON mode
from recognized pre-delimiter options in that snapshot.

**Evidence:** `test/integration/cli_version_test.rb` and
`test/e2e/lib/hive_e2e_binary_test.rb` cover literal post-delimiter help and
invalid JSON assignments plus both true/false JSON precedence directions.
Focused wrapper suites, adjacent `hive new` and JSON usage-error suites,
targeted RuboCop, and the full 7,281-test suite pass.
