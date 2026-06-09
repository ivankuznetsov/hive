## [2026-06-09T18:15:28Z] wiki — audit babysitter textconv/index dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `872d6765` changed `bin/hive-babysitter-stub-git` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git textconv index writes"` surfaced prior babysitter dry-run changelog coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `lib/hive/babysitter/gh_ops.rb`, `lib/hive/babysitter/pr_fixer.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] and [[modules/babysitter]] so the dry-run `git` stub surface documents both new safeguards: exact `--textconv` plus every Git-accepted abbreviation down to `--t` are skipped before read passthrough, and allowed reads execute with `GIT_OPTIONAL_LOCKS=0` so `git status`-class reads cannot refresh `.git/index`. Refreshed [[testing]] for the new exact/abbreviated textconv regression coverage, and refined [[gaps]] to keep the live-agent dry-run smoke uncertainty open while also noting that no in-tree live artifact proves the optional-lock no-index-write behavior under a real project workload. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
