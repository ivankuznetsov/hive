## [2026-06-09T17:50:16Z] wiki — audit babysitter git-stub command surface

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `6975bc7` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command API surface routes handlers commands executable entrypoints README babysitter"` surfaced existing command/testing/log coverage, and the configured master wiki path had no relevant hit. Inspected the committed diff plus current `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] so the user-facing dry-run command surface names the new `--textconv` rejection and the hermetic allowed-read passthrough controls: neutralized HOME/XDG config, disabled system/global git config, cleared trace/config/SSH/pager env seams, `core.fsmonitor=false`, and `--no-ext-diff --no-textconv` for `diff` / `log` / `show`. Refreshed [[modules/babysitter]] and [[testing]] metadata/coverage wording, removed stale duplicate dry-run test wording, and updated [[gaps]] to record that this audit still found no live-agent `hive babysit --once PROJECT --dry-run` artifact after the 2026-06-09 stub hardening. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
