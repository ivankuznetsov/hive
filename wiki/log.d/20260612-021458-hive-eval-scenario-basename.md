## [2026-06-12T02:14:58Z] testing/wiki - refresh hive-eval scenario selector coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after
commit `75ccfb35` changed `bin/hive-eval` scenario selection. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search
"hive-eval executable scenario basename validation"` found only the existing
wiki changelog context, and the configured master wiki path had no matching
context.

Inspected the committed diff plus current `bin/hive-eval`, `Rakefile`,
`test/eval/support/reporter_test.rb`, `test/eval/support/reporter.rb`, and
`test/eval/scenarios/s3_noise_test.rb`. Documented that `--scenario` now
accepts only safe basenames (`[A-Za-z0-9_-]+` after optional `_test` stripping),
rejects slash/backslash path separators and other unsafe names with exit 64
before report creation, and continues to ignore ambient `TEST` while routing
through `HIVE_EVAL_SCENARIOS_ONLY`. Corrected stale eval docs for `s3_noise`:
the scenario now pins daemon-enabled notification suppression rather than an
intentional baseline failure. Updated the source coverage map to include
`bin/hive-eval` and recorded that no in-tree artifact shows a live non-test
`bin/hive-eval --scenario` invocation after the hardening. Updated [[index]]
metadata because executable-entrypoint coverage changed. Did not edit compiled
[[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]
- [[index]]
