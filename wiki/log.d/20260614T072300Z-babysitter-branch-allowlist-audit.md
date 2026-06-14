---
ts: 2026-06-14T07:23:00Z
slug: babysitter-branch-allowlist-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: audit babysitter git branch dry-run allowlist coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `7e7cc939` changed `bin/hive-babysitter-stub-git` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], recent [[log]] entries, and relevant babysitter dry-run fragments first; `qmd search "git branch allowlist mutation capable babysitter dry run"` surfaced existing [[commands/babysit]], [[gaps]], and changelog coverage, and the configured master wiki path had no relevant project-specific hit. Inspected the committed diff plus current `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] and [[modules/babysitter]] so the dry-run git stub contract says `git branch` passes only exact read forms: bare, `--show-current`, `--contains`, `--contains <rev>`, or `--contains=<rev>`. Mixed mutation-capable branch invocations such as delete, rename, or upstream-setting flags are skipped even when they also include `--contains` or `--show-current`. Refreshed [[testing]] for the new focused dry-run branch allowlist regressions and kept [[gaps]] explicit that no checked-in live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
