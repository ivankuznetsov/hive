# babysitter dry-run skip-log path pinning

Hardened `Hive::Babysitter::DryRunEnv` so the generated `git` / `gh`
dry-run launchers reset `HIVE_BABYSITTER_DRY_RUN_LOG` to the worktree-root
`.babysitter-dry-run-skipped.log` before invoking the shared stubs. This
matches the existing real-binary handoff pattern and prevents a command-local
log-path override from redirecting skipped-command audit records to an
agent-chosen user-owned file.

Added `test_with_env_pins_skip_log_against_command_local_overrides` to
`test/unit/babysitter/dry_run_env_test.rb`; it proves both skipped `git` and
`gh` commands still log to the worktree skip log while the override file remains
unchanged.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
