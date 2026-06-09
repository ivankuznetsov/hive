---
ts: 2026-06-09T10:15:40Z
slug: babysitter-grep-pager-abbrev-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: refresh babysitter grep pager abbreviation coverage

**Action:** Refreshed wiki coverage after commit `a7088180` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], and added the source-change fragment `20260609-101443-babysitter-grep-pager-abbrev-and-cluster-parse`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the new fragment first; `qmd search "babysitter git grep abbreviated open-files-in-pager value taking short option"` returned no indexed hits, and the configured master wiki path had no relevant cross-project hit. Inspected the committed diff plus the current git/gh dry-run stubs, `Hive::Babysitter::DryRunEnv`, `Hive::Babysitter::GhOps`, focused dry-run/rebase tests, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Updated command/module/testing/gap coverage so the dry-run contract includes abbreviated `git grep --open-files-in-pager` spellings down to `--op`, precise short-cluster parsing, and value-taking grep options such as `-eTODO` / `-fNEEDLEFILE.txt` remaining allowed. The existing uncertainty remains unchanged: no checked-in live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
- [[log]]
