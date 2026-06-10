---
ts: 2026-06-09T10:03:00Z
slug: babysitter-grep-cluster-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: audit babysitter clustered grep pager guard coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `2c62e0e9` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and the babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter git grep pager open-files-in-pager dry-run stub"` returned existing babysitter command/module coverage plus prior dry-run changelog history, and the configured master wiki path had no relevant cross-project hit. Checked the git stub, the `DryRunEnv` PATH overlay, the gh stub boundary, the focused dry-run env test, [[commands/babysit]], [[modules/babysitter]], and [[testing]]. Confirmed the documented command/module behavior matches the code: `git grep` now skips `--open-files-in-pager` plus glued, separate, and clustered short `-O` pager forms such as `-nO<cmd>`, while `diff`/`log`/`show -O` ordering reads stay allowed. Updated [[gaps]] to keep the missing live `hive babysit --once PROJECT --dry-run` agent-smoke uncertainty current. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
