## [2026-06-09T17:41:15Z] babysitter — hermetic git dry-run passthrough config

**Action:** Hardened `bin/hive-babysitter-stub-git` so allowlisted read passthrough no longer inherits user/system git config or local exec-capable diff/fsmonitor behavior. The stub now neutralizes `HOME` / `XDG_CONFIG_HOME`, disables system/global config for real git, forces `core.fsmonitor=false`, injects `--no-ext-diff --no-textconv` on `diff` / `log` / `show`, and rejects explicit `--textconv`.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with real-git regressions for HOME `.gitconfig`, `XDG_CONFIG_HOME/git/config`, local `.git/config diff.external`, local textconv, and local `core.fsmonitor`.

**Links:** [[modules/babysitter]], [[testing]], [[gaps]]
