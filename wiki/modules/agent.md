---
title: Hive::Agent
type: module
source: lib/hive/agent.rb, lib/hive/agent_limit.rb, lib/hive/claude_launcher.rb
created: 2026-04-25
updated: 2026-06-07
tags: [agent, claude, subprocess]
---

**TLDR**: Agent subprocess wrapper. Sets `AGENT_WORKING` pre-spawn for marker-owned spawns, streams stdout/stderr to the per-stage log, captures a bounded final-message summary, enforces budget + timeout, kills on signal or timeout, classifies provider account/rate/quota limits before generic failures, and translates the exit into a status/marker according to the selected `AgentProfile` status mode. The state file is mutated atomically by `Markers.set` (tempfile + rename); `Markers.current` always reads a complete file.

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

## Provider-limit classification

`Hive::AgentLimit` is the shared classifier for provider account, rate, quota, billing, and usage-credit exhaustion. It normalizes ANSI/control-heavy terminal text before matching Claude's limit menu and common API error strings such as quota exhaustion, 429 too-many-requests responses, resource exhaustion, usage credits, and billing/limit language. `error_message(text, agent:)` prefixes the first useful normalized line with `limits reached` or `limits reached for <agent>`. `AgentLimit` also owns the limit-retry cooldown: `RETRY_COOLDOWN_SEC` (default 3600s = 1h, overridable per-process via `HIVE_LIMITS_RETRY_COOLDOWN_SEC`, validated to a positive integer) and `retry_after(now:)`, which returns `(now.utc + cooldown).iso8601`. Every `limits_reached` marker writer stamps that `retry_after` so the daemon healer can self-heal the parked task once the usage window has plausibly reset — see [[daemon]] and [[state-model]].

Headless `Hive::Agent#handle_exit` only runs this classifier when the child failed or timed out; a clean `exit_code == 0` result is not reclassified. For `:state_file_marker` spawns it stamps `ERROR reason=limits_reached`; for `:exit_code_only` and `:output_file_exists` spawns it returns the limit message without overwriting the orchestrator-owned marker. `Hive::ClaudeLauncher` uses the same classifier while waiting for tmux readiness, terminal markers, and expected-output files, so a visible provider-limit pane wins over readiness timeout, tmux-session-death, and missing-output fallbacks.

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

Claude/tmux launches that use `status_mode: :output_file_exists` (reviewers, triage/browser helpers) poll the expected artifact and the managed tmux session together. If the session disappears before the expected file exists and is non-empty, `Hive::ClaudeLauncher` returns `status: :error` with `tmux_session_terminated...` instead of waiting for the full reviewer timeout. If the expected artifact is non-empty and Claude's Stop hook already wrote `.done`, the result is accepted as `:ok`; a non-empty artifact without `.done` is treated as partial and retried rather than being promoted as a successful review. Claude/tmux pane tails are also scanned for provider-limit UI such as Claude's "Stop and wait for limit to reset" / "Add funds to continue with usage credits" menu. When that appears, marker-owned waits stamp `ERROR reason=limits_reached` and expected-output waits return an error message beginning `limits reached for claude:` instead of surfacing generic readiness, timeout, or tmux-session-death errors.

## `handle_exit`

| Condition | Marker set |
|-----------|------------|
| provider-limit text in a failed/timeout result's `final_message` | `<!-- ERROR reason=limits_reached message="limits reached for <agent>: ..." marker_id=<hex16> -->` for `:state_file_marker`; other status modes return `result[:error_message] = "limits reached for <agent>: ..."` without clobbering orchestrator-owned markers |
| `result[:timed_out]` | `<!-- ERROR reason=timeout timeout_sec=N marker_id=<hex16> -->` |
| `exit_code` non-zero | `<!-- ERROR reason=exit_code exit_code=N marker_id=<hex16> -->` |
| `exit_code` is nil **and** marker is `:none` | `<!-- ERROR reason=no_marker_no_exit_code marker_id=<hex16> -->` (corrupted state, not silent OK) |
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
