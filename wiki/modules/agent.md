---
title: Hive::Agent
type: module
source: lib/hive/agent.rb
created: 2026-04-25
updated: 2026-05-25
tags: [agent, claude, subprocess]
---

**TLDR**: Agent subprocess wrapper. Sets `AGENT_WORKING` pre-spawn for marker-owned spawns, streams stdout/stderr to the per-stage log, captures a bounded final-message summary, enforces budget + timeout, kills on signal or timeout, and translates the exit into a status/marker according to the selected `AgentProfile` status mode. The state file is mutated atomically by `Markers.set` (tempfile + rename); `Markers.current` always reads a complete file.

## Class shape

```ruby
Hive::Agent.new(
  task:,                # Hive::Task
  prompt:,              # rendered ERB string
  max_budget_usd:,      # required, no default
  timeout_sec:,         # required, no default
  add_dirs: [],         # extra --add-dir paths
  cwd: nil,             # defaults to task.folder
  log_label: nil,       # defaults to task.stage_name
  profile: nil,         # AgentProfile; defaults to claude profile
  expected_output: nil, # used by :output_file_exists profiles
  status_mode: nil,     # per-spawn override
  permission_mode: nil  # Claude-only override; nil uses profile default/config caller
)
```

## Constants

- `FINAL_MESSAGE_TAIL_BYTES = 64 * 1024` caps the plain stdout/stderr tail retained in `result[:final_message]` when no structured final agent message was parsed.

## `run!` (the main entry)

1. `ensure_log_dir`.
2. `Markers.set(state_file, :agent_working, pid: Process.pid, started: now)`.
3. `spawn_and_wait` — see below.
4. `handle_exit`: translate timeout / non-zero exit / missing-marker-after-clean-exit into the appropriate status/marker for the selected status mode.
5. Return the result hash.

There is **no inode-tracking concurrent-edit detection.** It was tried in early Phase 1 and removed — claude's own `Edit` and `Write` tools rewrite atomically (write tempfile + rename), changing the state file's inode every time. Inode mismatch was 100% false-positive. The current safety net for "user edits state file mid-run" is the documented "don't edit during AGENT_WORKING" rule plus the per-task `.lock` file's PID-liveness probe.

## `build_cmd`

`build_cmd` composes argv from the selected `AgentProfile`, not from a
hardcoded Claude template:

```
<profile.bin> <profile.headless_flag>
  <permission flags>
  [<profile.add_dir_flag> <dir> ...]
  [<profile.budget_flag> <amount>]
  <profile.output_format_flags...>
  <prompt>
```

For the built-in Claude profile this is still:

```
claude -p
  --dangerously-skip-permissions
  [--add-dir <dir> ...]
  --max-budget-usd <amount>
  --output-format stream-json
  --include-partial-messages
  --verbose
  --no-session-persistence
  <prompt>
```

`--verbose` is required by `claude` whenever `-p` is paired with
`--output-format stream-json`; without it claude rejects the invocation
with `"Error: When using --print, --output-format=stream-json requires
--verbose"`. `--no-session-persistence` ensures every invocation starts
fresh.

Claude permission flags are configurable per spawn. If no
`permission_mode:` is supplied, the profile's `permission_skip_flag`
is used (`--dangerously-skip-permissions` for Claude). If
`permission_mode: "bypassPermissions"` is supplied, Hive keeps using the
skip flag for backward-compatible headless behavior. Any other Claude
permission mode is emitted as `--permission-mode <mode>`; current config
validation accepts `acceptEdits`, `auto`, `bypassPermissions`, `default`,
`dontAsk`, and `plan`.

## `spawn_and_wait` (the long part)

1. Open a logfile (`<task.log_dir>/<label>-<UTC-ts>.log`), append a `[hive] <ts> spawn cwd=… cmd=…` line.
2. `IO.pipe` for child stdout/stderr.
3. `Process.spawn(*cmd, chdir: cwd, pgroup: true, out: w, err: w)` — `pgroup: true` puts the child in its own process group so we can kill the entire group on signal/timeout.
4. Capture `pgid` (with `Errno::ESRCH` fallback to pid).
5. `Hive::Lock.update_task_lock(task.folder, "claude_pid" => pid)` — `hive status` uses this to detect stale agents.
6. Trap `INT`/`TERM` to forward `kill -TERM -<pgid>`. Old handlers are restored in `ensure`.
7. Reader thread: `r.each_line` writes timestamped lines to the log and captures the last structured agent final message it recognizes. Claude-style `result` / `assistant` events and Codex-style `item.completed` assistant messages set `result[:final_message_source] = :structured`; non-JSON output is retained as a bounded plain tail with `:plain` source.
8. Polling loop: `Process.wait(pid, WNOHANG)` every `[remaining, 0.2].min` seconds until the deadline.
9. On timeout: `kill_group(pgid)` (TERM), then `sleep_grace_then_kill` (3s grace, then KILL).
10. Reap with `Process.wait(pid)` (rescuing `Errno::ECHILD`).
11. Join the reader thread (kill if still alive after 2s).
12. Return `{pid, pgid, exit_code, timed_out, log_file, final_message, final_message_source, status: nil}`.

`final_message` is for orchestrators that need a human-readable agent answer even when the agent does not edit the state file. 4-execute writes this into `task.md` under `## Execute Output`; only structured final messages satisfy research-mode completion.

## `handle_exit`

| Condition | Marker set |
|-----------|------------|
| `result[:timed_out]` | `<!-- ERROR reason=timeout timeout_sec=N -->` |
| `exit_code` non-zero | `<!-- ERROR reason=exit_code exit_code=N -->` |
| `exit_code` is nil **and** marker is `:none` | `<!-- ERROR reason=no_marker_no_exit_code -->` (corrupted state, not silent OK) |
| Otherwise | `result[:status] = Markers.current(state_file).name` (trust the marker the agent wrote) |

`exit_code` can come back nil when claude streams large output and the parent's pipe-drain race loses the WNOHANG status; in that case we trust the marker the agent wrote. The nil-and-`:none` combination is treated as failure because a successful agent always writes a known marker.

## Why these three boundaries matter

The default Claude permission path still uses `--dangerously-skip-permissions` (`bypassPermissions`). Three controls keep this safe under the single-developer trust model:

1. **`--add-dir` discipline**: the agent only sees `cwd` and explicit `--add-dir` paths. Other projects on disk are unreachable.
2. **Status-mode ownership**: marker-owning stages use `:state_file_marker`; reviewer-style spawns can use `:output_file_exists` so the orchestrator, not the reviewer, owns terminal markers.
3. **Timeout + budget**: hard cap on runaway loops. Even an infinite loop costs at most $50–$100 (per-stage `max_budget_usd`) and ~45 minutes (`timeout_sec`).

## Tests

- `test/unit/agent_test.rb` and `test/fixtures/fake-claude` exercise the spawn/wait/timeout logic without a real claude binary, including configurable Claude permission-mode argv.
- `test/unit/spawn_agent_test.rb` covers `Stages::Base.spawn_agent` forwarding `claude.permission_mode` from config into headless Claude spawns.

## Backlinks

- [[modules/task]] · [[modules/markers]] · [[modules/lock]]
- [[modules/agent_profile]] · [[modules/config]]
- [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/artifacts]] · [[stages/finalize]]
- [[architecture]]
