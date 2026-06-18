---
date: 2026-06-17
slug: hive-eval-no-judge-env
pages: [testing, gaps]
---

Refreshed command/API and executable-entrypoint wiki coverage after commit
`ed404213` changed the checkout-local `bin/hive-eval` runner. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. Read-only
`qmd search "bin hive-eval inherited env judge"` surfaced the existing
[[testing]] eval-runner coverage and prior gap/log context; the configured
master wiki path had no matching Hive-specific entries.

Inspected the committed diff plus current `bin/hive-eval`,
`test/eval/support/reporter_test.rb`, the relevant eval support/scenario files,
[[testing]], and [[gaps]]. Documented that `bin/hive-eval` now owns
`HIVE_EVAL_NO_JUDGE`: it passes `1` only when `--no-judge` is present and
otherwise clears an inherited value before invoking `bundle exec rake
test:eval`, so a caller's environment cannot silently downgrade a judged eval
run into structural-only mode. Updated [[gaps]] to record the focused
env-clearing fixture and carry forward the remaining uncertainty: no in-tree
artifact was found for a full `bin/hive-eval` run with real Codex judge/persona
calls enabled after `ed404213`. No page was added, so [[index]] did not need a
catalog update. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.
