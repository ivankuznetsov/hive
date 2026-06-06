## [2026-06-07T17:32:29Z] wiki - audit hive-eval scenario basename coverage

**Action:** Refreshed executable-entrypoint and eval API wiki coverage after the PR #339 rebase changed `bin/hive-eval`, `test/eval/support/reporter_test.rb`, and [[testing]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hive-eval scenario names traversal eval reporter"` found the original eval harness log entry, and the configured master wiki path had no matching context. Inspected the rebased diff plus current `bin/hive-eval`, `test/eval/support/reporter_test.rb`, [[testing]], and relevant source-map/gap coverage. Tightened [[testing]] so the public `--scenario NAME` contract records separator rejection, optional `.rb` / `_test` suffix normalization, the exact safe-basename regex, the test-only `HIVE_EVAL_SCENARIO_ROOT` override, and the exit-64/no-report-on-invalid boundary. Updated [[gaps]] to include `bin/hive-eval` in the representative testing/eval coverage map and to carry forward the remaining uncertainty that the map is manual rather than generated. Page count stayed 75, so [[index]] did not need a catalog update. Did not edit compiled `wiki/log.md`, and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]
