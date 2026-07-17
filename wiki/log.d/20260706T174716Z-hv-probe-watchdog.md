## [2026-07-06T17:47:16Z] cli/install - harden hv version probe watchdog

**Action:** Fixed Hive patrol finding `command-bin-hv-1` (bug/medium): the
`bin/hv` GNU `timeout` fast path let a bad candidate's stdout feed the wrapper's
command substitution directly, so a forked helper that inherited stdout could
hold the pipe open after the wrapper timed out.

Removed the GNU `timeout` shortcut so every candidate uses the existing temp-file
stdout capture, process-group watchdog, and post-wait KILL sweep. Added
`HvTest#test_timeout_present_probe_tree_uses_watchdog_and_does_not_leak_stdout_pipe`,
which puts a fake `timeout` on `PATH`, exercises a TERM-ignoring
stdout-inheriting helper, verifies `hv` falls through to the next candidate, and
checks the helper is not left behind.

**Refreshed pages:**
- [[cli]]
- [[testing]]
