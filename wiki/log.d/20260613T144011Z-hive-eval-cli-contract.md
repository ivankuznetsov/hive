---
date: 2026-06-13
slug: hive-eval-cli-contract
pages: [testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`ffa51d56` changed the checkout-only `bin/hive-eval` runner. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "command API surface routes handlers executable entrypoints README"`
surfaced existing executable/test coverage, and the configured master wiki path
had only generic route-coverage guidance.

Inspected the committed diff plus current `bin/hive-eval`,
`test/eval/support/reporter_test.rb`, [[testing]], [[modules/bot]],
[[active-areas]], and [[gaps]]. Updated [[testing]] to document the eval
runner's usage contract: scenario selection must use `--scenario`, positional
arguments exit 64 before report creation, `--scenario` is resolved by safe
basename under `test/eval/scenarios/`, and path separators/traversal/dotted
names are rejected before the runner sets `TEST`. Corrected stale eval wording:
`s3_noise` now passes and pins daemon-enabled ready-row noise suppression, while
the reporter failure path uses a temporary `HIVE_EVAL_SCENARIO_ROOT` fixture.

Updated [[gaps]] so the source-coverage map names `bin/hive-eval` alongside the
other test/e2e executables, and recorded the remaining uncertainty: no in-tree
artifact was found for a full judge-enabled `bin/hive-eval` run after the
hardening. No new page was added, so [[index]] needed no catalog change.

Verified with `bundle exec ruby -Itest test/eval/support/reporter_test.rb`
(`16 runs, 91 assertions, 0 failures, 0 errors, 0 skips`). Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.
