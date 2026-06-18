---
date: 2026-06-18
slug: babysitter-gh-short-w-value-options
pages: [commands/babysit, modules/babysitter, testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`1dab816a` changed `bin/hive-babysitter-stub-gh` and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "babysitter dry-run"`
surfaced prior babysitter fragments; `qmd search "babysitter gh stub short -w
workflow dry-run"` had no exact hit. The configured master wiki path had no
Hive-specific guidance. The compiled [[log]] is stale relative to newer
`wiki/log.d/` fragments, so recent babysitter fragments were checked directly
without editing [[log]].

Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`,
`test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]],
[[modules/babysitter]], [[testing]], and [[gaps]]. The GH dry-run stub still
skips browser-launch forms such as `--web`, bare `-w`, and short clusters where
`w` is parsed as an option flag. It now keeps command-specific value-taking
options from misclassifying `w` inside their values: examples pinned by tests
include `gh pr diff 42 -eworkflow.yml`, `gh pr list -lwip`, `gh pr view 42
-qweb`, and `gh pr list --search -wip`. Updated command/module/testing coverage
and recorded the remaining uncertainty that no checked-in artifact proves a full
live-agent `hive babysit --once PROJECT --dry-run` run after this GH stub parser
change. Page coverage stayed within existing pages, so [[index]] did not need a
catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
