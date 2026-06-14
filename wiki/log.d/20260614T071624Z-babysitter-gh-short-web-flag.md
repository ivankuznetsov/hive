---
date: 2026-06-14
slug: babysitter-gh-short-web-flag
pages: [commands/babysit, modules/babysitter, testing, gaps]
---

Post-commit command/API and executable-stub wiki refresh after commit
`73947cfc` changed `bin/hive-babysitter-stub-gh` and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "babysitter gh short web
flag dry run"` found existing [[testing]], [[gaps]], and prior dry-run log
coverage; targeted search of the configured master wiki path found no
Hive-specific guidance.

Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`,
[[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. The
change keeps the `gh` dry-run stub default-deny and narrows only the
browser-launch guard: short `-w` / `-w...` is now skipped for read-only `gh pr
checks`, `gh pr diff`, and `gh pr list`, matching the existing `gh pr view`,
`gh repo view`, `gh run view`, and `gh workflow view` protection; long `--web`
forms remain skipped. Updated command/module/testing coverage and carried
forward the existing uncertainty that no checked-in artifact proves a full
`hive babysit --once PROJECT --dry-run` live-agent run after these stub
changes. Page coverage did not change, so [[index]] was not edited. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
