## [2026-06-15T21:59:17Z] wiki — audit babysitter gh config-home dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `f12c46c7` changed `bin/hive-babysitter-stub-gh`, `Hive::Babysitter::DryRunEnv`, and dry-run tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], recent [[log]] entries, and relevant 2026-06-15 babysitter log fragments first; `qmd search "babysitter gh HOME redirects config dry-run stub env"` surfaced existing babysitter command/test/gap coverage, while the configured master wiki path had no matching project-specific context. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Refresh:** Documented that the dry-run `gh` wrapper captures the parent GitHub config directory (`GH_CONFIG_DIR`, else `XDG_CONFIG_HOME/gh`, else `HOME/.config/gh`) in `HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR`; the shared `gh` stub deletes command-local `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, `HOME`, and the private handoff env, then restores only the trusted path as `GH_CONFIG_DIR` and sets `HOME` to `File::NULL` before allowlisted passthrough. Updated command/module/testing coverage and consolidated the duplicate babysitter dry-run gap entry while carrying the remaining uncertainty forward: no checked-in artifact proves a full live `hive babysit --once PROJECT --dry-run` agent run after the dry-run stub/env hardening. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Verified:** `env -u GIT_EXEC_PATH -u GIT_EXTERNAL_DIFF -u GIT_SSH_COMMAND -u GIT_SSH -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_PROXY_COMMAND -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (16 runs, 1006 assertions). The unsanitized post-commit shell inherited `GIT_EXEC_PATH=/usr/lib/git-core`, which intentionally trips the git dry-run stub's env-seam guard and makes older git passthrough assertions fail even though the sanitized source behavior is green.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
