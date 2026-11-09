# 2026-11-06 — Project commands no longer inherit Hive's Ruby load path

**Action:** A hivedev review attempt ran its CI with `RUBYLIB` set to the dogfood
deployment's `lib`, `components/agent-cli-runtime/lib`, and ~40 gem lib dirs of
Hive's own runtime. hivedev's `require "hive"` loaded the deployed Hive instead
of its pinned hive-cli gem; 18 compat tests failed and CI hung to the 3600 s
timeout twice.

**Cause:** `Attempts::DetachedLauncher#fork_wrapper` sets
`RUBYLIB => trusted_runtime_load_path` (the controller's full `$LOAD_PATH`) so
the supervisor can re-enter Hive. The supervisor and worker inherit it, and
`CiFix.run_ci_once` / council `CommandRunner` spawned project commands with the
ambient environment.

**Change:** New `Hive::ProjectCommandEnvironment.overrides` unsets the Ruby and
Bundler toolchain keys (plus any `BUNDLER_ORIG_*`). Review CI and council
commands merge it; `Hive::Agent::SCRUBBED_TOOLCHAIN_ENV_KEYS` now reuses its key
list (adding `RUBYGEMS_GEMDEPS`). The supervisor's own re-entry path is unchanged.
Regression tests assert a project CI command, a council command, and an agent's
child environment see no Hive deployment lib.
