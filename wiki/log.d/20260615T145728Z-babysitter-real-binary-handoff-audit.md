## [2026-06-15T14:57:28Z] wiki — audit babysitter dry-run real-binary handoff coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `c8392dfa` touched `Hive::Babysitter::DryRunEnv`, dry-run tests, and babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the committed source-change fragment first. `qmd search "babysitter HIVE_BABYSITTER_REAL override dry-run"` surfaced older babysitter dry-run context, while the configured master wiki path had no relevant cross-project hit. Inspected the committed diff plus current `lib/hive/babysitter/dry_run_env.rb`, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], and [[testing]].

**Refresh:** Confirmed the command/module/testing pages already document the wrapper-launcher handoff: the PATH overlay now generates `git` / `gh` launchers that reset `HIVE_BABYSITTER_REAL_GIT` / `HIVE_BABYSITTER_REAL_GH` to parent-resolved paths before execing the shared stubs, preventing command-local overrides from redirecting allowlisted passthrough. Updated [[gaps]] to remove the stale duplicate dry-run entry and carry the current missing-evidence statement forward: no checked-in artifact proves a full live `hive babysit --once PROJECT --dry-run` agent run after the stub and wrapper-launcher hardening. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]
