---
title: Hive::Agent
type: module
source: lib/hive/agent.rb
created: 2026-04-25
updated: 2026-04-25
tags: [agent, claude, subprocess]
---

**TLDR**: `claude -p` subprocess wrapper. Sets `AGENT_WORKING` pre-spawn, streams stdout/stderr to the per-stage log, enforces budget + timeout, kills on signal or timeout, detects concurrent edits via inode tracking, and translates the exit into a marker (`COMPLETE` / `WAITING` / `ERROR`).

## Class shape

```ruby
Hive::Agent.new(
  task:,                # Hive::Task
  prompt:,              # rendered ERB string
  max_budget_usd:,      # required, no default
  timeout_sec:,         # required, no default
  add_dirs: [],         # extra --add-dir paths
  cwd: nil,             # defaults to task.folder
  log_label: nil        # defaults to task.stage_name
)
```

## Constants

- `DEFAULT_BIN = "claude"`. Override via `HIVE_CLAUDE_BIN` env var (used by tests via `test/fixtures/fake-claude`).
- `Hive::MIN_CLAUDE_VERSION = "2.1.118"` (defined in `lib/hive.rb`).

## `run!` (the main entry)

1. `ensure_log_dir`.
2. Snapshot `pre_inode = File.stat(state_file).ino`. Used later for concurrent-edit detection.
3. `Markers.set(state_file, :agent_working, pid: Process.pid, started: now)`.
4. `spawn_and_wait` — see below.
5. `post_inode = File.stat(state_file).ino`.
6. If `pre_inode != post_inode`, the state file was atomically replaced by an editor save (VSCode, vim "rename-then-mv"); set `<!-- ERROR reason=concurrent_edit_detected pre_inode=… post_inode=… -->` and mark `result[:status] = :concurrent_edit`.
7. `handle_exit`: translate timeout / non-zero exit / concurrent edit into the appropriate marker.
8. Return the result hash.

## `build_cmd`

```
claude -p
  --dangerously-skip-permissions
  [--add-dir <dir> ...]
  --max-budget-usd <amount>
  --output-format stream-json
  --include-partial-messages
  --no-session-persistence
  <prompt>
```

`--no-session-persistence` ensures every invocation starts fresh — no surprises from a previous session's state.

## `spawn_and_wait` (the long part)

1. Open a logfile (`<task.log_dir>/<label>-<UTC-ts>.log`), append a `[hive] <ts> spawn cwd=… cmd=…` line.
2. `IO.pipe` for child stdout/stderr.
3. `Process.spawn(*cmd, chdir: cwd, pgroup: true, out: w, err: w)` — `pgroup: true` puts the child in its own process group so we can kill the entire group on signal/timeout.
4. Capture `pgid` (with `Errno::ESRCH` fallback to pid).
5. `Hive::Lock.update_task_lock(task.folder, "claude_pid" => pid)` — `hive status` uses this to detect stale agents.
6. Trap `INT`/`TERM` to forward `kill -TERM -<pgid>`. Old handlers are restored in `ensure`.
7. Reader thread: `r.each_line` writes timestamped lines to the log.
8. Polling loop: `Process.wait(pid, WNOHANG)` every `[remaining, 0.2].min` seconds until the deadline.
9. On timeout: `kill_group(pgid)` (TERM), then `sleep_grace_then_kill` (3s grace, then KILL).
10. Reap with `Process.wait(pid)` (rescuing `Errno::ECHILD`).
11. Join the reader thread (kill if still alive after 2s).
12. Return `{pid, pgid, exit_code, timed_out, log_file, status: nil}`.

## `handle_exit`

| Condition | Marker set |
|-----------|------------|
| `result[:timed_out]` | `<!-- ERROR reason=timeout timeout_sec=N -->` |
| `result[:status] == :concurrent_edit` | already set by run! |
| `exit_code != 0` | `<!-- ERROR reason=exit_code exit_code=N -->` |
| Otherwise | `result[:status] = Markers.current(state_file).name` (read whatever marker the agent wrote) |

## `check_version!`

Class method called by stage runners (or smoke tests) to ensure the local `claude` is recent enough.

```
out = `claude --version`
version = out[/\d+\.\d+\.\d+/]
if compare(version, MIN_CLAUDE_VERSION) < 0
  raise AgentError
end
```

Compares as `[major, minor, patch]` integer tuples.

## Why these three boundaries matter

The agent runs with `--dangerously-skip-permissions`. Three controls keep this safe under the single-developer trust model:

1. **`--add-dir` discipline**: the agent only sees `cwd` and explicit `--add-dir` paths. Other projects on disk are unreachable.
2. **Inode tracking**: catches editor saves during a run that would silently overwrite the agent's marker write.
3. **Timeout + budget**: hard cap on runaway loops. Even an infinite loop costs at most $50–$100 (per-stage `max_budget_usd`) and ~45 minutes (`timeout_sec`).

## Tests

- `test/unit/agent_test.rb` and `test/fixtures/fake-claude` exercise the spawn/wait/timeout logic without a real claude binary.

## Backlinks

- [[modules/task]] · [[modules/markers]] · [[modules/lock]]
- [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/pr]]
- [[architecture]]
