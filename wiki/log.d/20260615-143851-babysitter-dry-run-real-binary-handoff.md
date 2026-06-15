## [2026-06-15T14:38:51Z] babysitter — pin dry-run real-binary handoff

**Action:** Hardened `Hive::Babysitter::DryRunEnv` so the dry-run PATH overlay generates `git` / `gh` wrapper launchers instead of symlinks directly to the shared stubs. Each launcher overwrites `HIVE_BABYSITTER_REAL_GIT` or `HIVE_BABYSITTER_REAL_GH` with the parent-resolved literal before execing the shared stub, so command-local `HIVE_BABYSITTER_REAL_*` overrides cannot redirect an allowlisted passthrough command to an attacker-chosen binary.

**Coverage:** Added `test_with_env_pins_real_binaries_against_command_local_overrides` to `test/unit/babysitter/dry_run_env_test.rb`, proving allowlisted `git status --short` and `gh repo view` reach the resolved fake real binaries and do not execute command-local override binaries.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]
