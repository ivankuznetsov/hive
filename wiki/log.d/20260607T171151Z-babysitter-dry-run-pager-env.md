## [2026-06-07T17:11:51Z] babysitter — harden dry-run pager/browser exec paths

**Action:** Hardened the babysitter dry-run `git` / `gh` stubs after patrol found TTY pager execution still reachable through allowlisted reads. `bin/hive-babysitter-stub-git` now treats global `-p` / `--paginate` as exec-screened options and deletes generic `PAGER` before handoff in addition to the existing Git-specific env scrub. `bin/hive-babysitter-stub-gh` now deletes `GH_PAGER`, `PAGER`, `GH_BROWSER`, and `BROWSER` before handoff, and skips documented browser-opening `--web` / `-w` flags on read subcommands while preserving non-browser `gh run list -w <workflow>`.

**Coverage:** `test/unit/babysitter/dry_run_env_test.rb` now runs focused PTY regressions with hostile pager/browser env vars, verifies forced git pagination is skipped without invoking the real binary, and keeps safe read forms such as `git log -p -1` and `gh run list -w CI` passing.

**Refs:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]
