## [2026-06-15T14:49:42Z] wiki — audit babysitter dry-run real-binary handoff

**Action:** Refreshed wiki planning/documentation coverage after commit `f9d2dcf0` changed `Hive::Babysitter::DryRunEnv`, `test/unit/babysitter/dry_run_env_test.rb`, and the babysitter/testing wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run real binary handoff HIVE_BABYSITTER_REAL_GIT HIVE_BABYSITTER_REAL_GH"` returned no indexed hits, so verification used direct source/wiki search plus the configured master wiki path, which had no relevant cross-project context.

**Coverage:** Inspected the committed diff and current `lib/hive/babysitter/dry_run_env.rb`, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Confirmed the command/module/testing pages already describe the new wrapper-launcher handoff and command-local `HIVE_BABYSITTER_REAL_*` override resistance. Updated [[gaps]] so the remaining live-agent dry-run smoke uncertainty includes the June 15 wrapper/env hardening. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
