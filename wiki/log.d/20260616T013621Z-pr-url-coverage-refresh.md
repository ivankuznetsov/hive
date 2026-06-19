## [2026-06-16T01:36:21Z] wiki — refresh PR URL coverage-gate documentation

**Action:** Refreshed wiki planning/documentation coverage after commit
`03af0d71` (`test: cover PR URL defensive branches`) added focused tests for
three previously uncovered defensive paths and touched [[testing]] plus a wiki
log fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "PR URL
defensive branches status dispatcher pr_url"` found existing state-model/log
context, and the configured master wiki path had no matching PR URL or digest
scheduler entries.

Inspected the committed diff plus current `lib/hive/pr.rb`,
`lib/hive/commands/status.rb`, `lib/hive/daemon/dispatcher.rb`,
`test/unit/pr_test.rb`, `test/unit/commands/status_test.rb`,
`test/unit/daemon/dispatcher_test.rb`, [[modules/pr]], [[commands/status]],
[[modules/daemon]], [[modules/digest]], and [[testing]]. Updated [[modules/pr]]
so its API/test coverage includes the shared `valid_http_url?` link-safety
predicate and invalid-URI rejection; updated [[modules/daemon]] and
[[modules/digest]] to document digest scheduler `tick` / `complete` fatal-log
isolation and dry-run pseudo-child completion; and carried the new focused-test
coverage into [[gaps]] while preserving the missing live digest, TTY, status,
and Telegram smoke uncertainties. Page coverage did not change, so [[index]]
did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/pr]]
- [[modules/daemon]]
- [[modules/digest]]
- [[gaps]]
- [[log]]
