---
date: 2026-06-13
slug: hive-eval-usage-refresh
pages: [testing, gaps]
---

Refreshed command/API and executable-entrypoint wiki coverage after the
eval-wrapper follow-up changed the checkout-local `bin/hive-eval` wrapper and
its reporter tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], and recent compiled [[log]] entries
first. Read-only `qmd search "hive-eval usage validation scenario selector"`
surfaced prior wiki log context but no fresher eval-runner page; targeted
search of the configured master wiki path found no Hive-specific eval guidance.

Inspected the committed diff plus current `bin/hive-eval`,
`test/eval/support/reporter_test.rb`, `test/eval/support/reporter.rb`,
`test/eval/scenarios/s3_noise_test.rb`, `test/eval/support/contract_assertions.rb`,
`test/eval/support/reason_classifier.rb`, `Rakefile`, `hive.gemspec`,
[[testing]], and [[gaps]]. Verified [[testing]] documents the
current OptionParser wrapper boundary: only `--scenario`, `--report`, and
`--no-judge` are accepted; usage errors exit `64` before report creation;
unexpected positional arguments use count-aware `argument` / `arguments`
wording; scenario selection is basename-only with separate separator and
unsafe-character checks; inherited `TEST` is cleared; and
`HIVE_EVAL_SCENARIO_ROOT` is the tmpdir fixture seam. Updated [[gaps]] so the
source map and open eval gap use the current reachable selector-hardening commit
and record the remaining full judged-eval smoke uncertainty. The focused
reporter suite now pins both positional-scenario and trailing-extra-argument
usage errors. [[index]] did not need a page-list update because page coverage
did not change. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.
