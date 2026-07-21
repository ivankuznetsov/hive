---
title: Hive::Agent
type: module
source: lib/hive/agent.rb, lib/hive/agent_limit.rb, lib/hive/claude_launcher.rb, lib/hive/scripts/interactive_claude_wrapper.sh
created: 2026-04-25
updated: 2026-07-21
tags: [agent, claude, subprocess]
---

**TLDR**: Agent subprocess wrapper. Sets `AGENT_WORKING` pre-spawn for marker-owned spawns, streams stdout/stderr to the per-stage log, captures a bounded final-message summary, enforces native budget-equivalent, streamed token, optional completed-turn, and wall-clock limits, kills the process group on exhaustion or completed output, classifies provider account/rate/quota limits before generic failures, and translates the exit into a status/marker according to the selected `AgentProfile` status mode. The state file is mutated atomically by `Markers.set` (tempfile + rename); `Markers.current` always reads a complete file.

## Class shape

```ruby
Hive::Agent.new(
  task:,                # Hive::Task
  prompt:,              # rendered ERB string
  max_budget_usd:,      # required, no default
  max_tokens: nil,      # optional positive in-flight token ceiling
  max_turns: nil,       # optional positive Claude completed-turn ceiling
  timeout_sec:,         # required, no default
  add_dirs: [],         # extra --add-dir paths
  cwd: nil,             # defaults to task.folder
  log_label: nil,       # defaults to task.stage_name
  profile: nil,         # AgentProfile; defaults to claude profile
  expected_output: nil, # used by :output_file_exists profiles
  status_mode: nil,     # per-spawn override
  permission_mode: nil, # profile-owned override; nil uses profile default/config caller
  allowed_tools: nil,   # Claude-only --allowedTools CSV source
  disallowed_tools: nil,# Claude-only --disallowedTools CSV source
  cli_flags: []         # per-run Claude argv extras (model/effort or verified capabilities)
)
```

## Constants

- `FINAL_MESSAGE_TAIL_BYTES = 64 * 1024` caps the plain stdout/stderr tail retained in `result[:final_message]` when no structured final agent message was parsed.
- `TERMINATION_GRACE_SECONDS = 3` bounds graceful shutdown after a streamed token ceiling, completed-turn ceiling, or completed expected output before Hive escalates the process group to KILL.
- `COMPLETION_EVENT_GRACE_SECONDS = 3` lets an already-generated Claude `Write`
  and its usage-bearing turn delta settle in either event order; expiry or a
  next-turn start sends TERM, so the protocol allowance cannot become another
  reasoning turn.

## Provider-limit classification

`Hive::AgentLimit` is the shared classifier for provider account, rate, quota, billing, and usage-credit exhaustion. It normalizes ANSI/control-heavy terminal text before matching Claude's limit menu and common API error strings such as quota exhaustion, 429 too-many-requests responses, resource exhaustion, usage credits, and billing/limit language. The broad "limit reached/exceeded/reset" family is intentionally usage-qualified (`usage`, `rate`, `token`, `credit`, `quota`, account/subscription/time-window terms, etc.) so healthy agent output about UI limits such as scroll, window, viewport, page, buffer, or line limits does not trip a false `limits_reached` wall. `error_message(text, agent:)` prefixes the first useful normalized line with `limits reached` or `limits reached for <agent>`. `AgentLimit` also owns the periodic readiness interval: `RETRY_COOLDOWN_SEC` (default 3600s = 1h, overridable per-process via `HIVE_LIMITS_RETRY_COOLDOWN_SEC`, validated to a positive integer). `retry_after(text:, now:)` still preserves a complete provider reset estimate for status/TUI display, falling back to `now + cooldown`, but daemon scheduling deliberately ignores that estimate: `retry_due?` uses the latest quota marker's mtime so credits, usage resets, and account switches are noticed within one interval. See [[daemon]] and [[state-model]].

Headless `Hive::Agent#spawn_and_wait` scans each raw stream line for limit text while still preserving the structured final message and bounded plain tail. That raw-stream path catches CLIs that emit usage walls as JSON error events which `MessageExtractor` does not surface as a final assistant message; `handle_exit` then prefers `result[:limit_text]` and falls back to scanning `final_message`. The classifier still only controls failure/timeout handling: a clean `exit_code == 0` result is not reclassified. For `:state_file_marker` spawns it stamps `ERROR reason=limits_reached`; for `:exit_code_only` and `:output_file_exists` spawns it returns the limit message without overwriting the orchestrator-owned marker. `Hive::ClaudeLauncher` uses the same classifier while waiting for tmux readiness, terminal markers, and expected-output files, so a visible provider-limit pane wins over readiness timeout, tmux-session-death, and missing-output fallbacks.

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
  [--allowedTools <csv>]
  [--disallowedTools <csv>]
  [<profile.budget_flag> <amount>]
  [<cli_flags...>]
  <profile.output_format_flags...>
  <prompt>
```

Prompt placement is profile data: Claude/Pi use a trailing positional prompt,
Codex sends the prompt through stdin and places `-` in argv, and Grok places
the prompt immediately after `-p` because `--single` consumes a value. Grok's
streaming `text` fragments are concatenated verbatim into `final_message`.

For the built-in Claude profile this is still:

```
claude -p
  --dangerously-skip-permissions
  [--add-dir <dir> ...]
  [--allowedTools <csv>]
  [--disallowedTools <csv>]
  --max-budget-usd <amount>
  [--model <claude.model>]
  [--effort <claude.effort>]
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

Permission flags are profile-owned and configurable per spawn. For Claude, if no
`permission_mode:` is supplied, the profile's `permission_skip_flag`
is used (`--dangerously-skip-permissions` for Claude). If
`permission_mode: "bypassPermissions"` is supplied, Hive keeps using the
skip flag for backward-compatible headless behavior. Any other Claude
permission mode is emitted as `--permission-mode <mode>`; current config
validation accepts `acceptEdits`, `auto`, `bypassPermissions`, `default`,
`dontAsk`, and `plan`.

`workspace-write` is a special Hive permission mode, not a Claude mode. It asks
the selected profile for `workspace_write_flags` and raises when that profile
cannot guarantee a root-confined writable sandbox. The built-in Codex profile
uses `--sandbox workspace-write`, approval policy `never`, ephemeral execution,
and ignored user config/rules; architecture-patrol auto-fix runs with that mode
and the isolated fix worktree as `cwd`.

Claude tool-scope flags are also per spawn. `allowed_tools:` and
`disallowed_tools:` are emitted only for the Claude profile and only when
non-empty, after `--add-dir` flags and before budget/model/output-format
flags. This preserves the historical yolo headless argv (no tool lists) while
letting `Hive::PermissionScope` enforce opt-in `read-only` and `scoped`
presets through `--allowedTools` / `--disallowedTools`. `read-only` uses
`permission_mode: "default"` with allowed tools `Read,LS,Grep,Glob` and
denies mutating/shell tools.

Claude model/effort flags are config-derived rather than profile-derived.
When `Stages::Base.spawn_agent` receives `cfg:` and the selected profile is
Claude, it passes `Hive::Config.claude_cli_flags(cfg)` into `cli_flags`.
That means `claude.model: default` reaches the headless argv as
`--model default`; `model: inherit` or blank omits `--model`; and
`claude.effort` reaches argv for any explicit non-default/non-inherit
value (fresh init offers `low`, `medium`, and `high`).
`Hive::ClaudeLauncher.wrapper_command` uses the same flag fragment for
tmux-backed Claude sessions, and the shell wrapper forwards `--model` and
`--effort` without shell re-parsing.

Read-only architecture discovery is a separate Claude-only launch contract.
`Hive::RefactorPatrol::ReviewAgentRunner` resolves the existing read-only tool
scope and also asks the profile for its verified `safe_mode` capability. Hive
runs `claude --safe-mode --help` once per binary/version/capability tuple and
fails closed if the installed or operator-overridden binary does not advertise
the flag. The resulting argv keeps `--safe-mode` ahead of project-controlled
customizations; unrelated Claude launches do not receive it. Discovery still
uses Claude's positional prompt, while Codex's normal and workspace-write
launches send the prompt through stdin with `-` in argv.

## `spawn_and_wait` (the long part)

1. Open an owner-private (`0600`), no-follow logfile (`<task.log_dir>/<label>-<UTC-ts>.log`). Append only bounded launch metadata (`cwd`, profile, executable basename, argv count); never serialize argv because positional profiles carry the complete prompt there. Event messages pass through the same shared secret redactor before persistence.
2. `IO.pipe` for child stdout/stderr.
3. `Process.spawn(*cmd, chdir: cwd, pgroup: true, out: w, err: w)` — `pgroup: true` puts the child in its own process group so we can kill the entire group on signal/timeout.
4. Capture `pgid` (with `Errno::ESRCH` fallback to pid).
5. `Hive::Lock.update_task_lock` records both `claude_pid` and
   `claude_pid_start_time = Hive::Lock.process_start_time(pid)`. `hive status`
   uses the PID for liveness, and drop cleanup uses the start time to reject a
   reused PID before signalling the recorded child.
6. Trap `INT`/`TERM` to forward `kill -TERM -<pgid>`. Old handlers are restored in `ensure`.
7. Reader thread: the shared stdout/stderr pipe is line-buffered before persistence, so credentials split across provider writes or the two streams are reassembled before `Hive::SecretPatterns.redact` runs. Only the redacted timestamped record reaches the `0600` log. Raw in-memory lines still feed structured final-message parsing, provider-limit detection, and usage metering. Claude-style `result` / `assistant` events and Codex-style `item.completed` assistant messages set `result[:final_message_source] = :structured`; non-JSON output is retained as a bounded plain tail with `:plain` source. When `max_tokens` is set, `StreamTokenMeter` also converts usage events into one monotonic count. Claude message-start/delta events sum completed turns while maxing cumulative current-turn fields; terminal run totals replace the aggregate only when they are not smaller than already observed usage.
8. Polling loop: `Process.wait(pid, WNOHANG)` every `[remaining, 0.2].min` seconds until the deadline. Reaching `max_tokens`, reaching the Claude `max_turns` ceiling, or observing a non-empty expected output begins termination. Claude can emit its local `Write` result before or after the same turn's usage-bearing `message_delta`, so Hive waits at most the completion-event grace for the missing half, captures the delta when available, and sends TERM before a next model turn. A process group still alive after the termination grace receives KILL independently of the longer wall-clock timeout.
9. On timeout: `kill_group(pgid)` (TERM), then `sleep_grace_then_kill` (3s grace, then KILL).
10. Reap with `Process.wait(pid)` (rescuing `Errno::ECHILD`).
11. Join the reader thread (kill if still alive after 2s).
12. Return `{pid, pgid, exit_code, timed_out, log_file, final_message, final_message_source, usage, resource_exhaustion, output_completed, status: nil}`. Resource exhaustion carries `reason: "token_limit"` or `"turn_limit"`, the configured limit, and the observed count. A completed output is accepted only in `:output_file_exists` mode and remains subject to the caller's structured parser.

`final_message` is for orchestrators that need a human-readable agent answer even when the agent does not edit the state file. 4-execute writes this into `task.md` under `## Execute Output`; only structured final messages satisfy research-mode completion.

Claude/tmux launches record the managed pane PID in the same per-task lock.
`Hive::ClaudeLauncher#record_claude_pid` waits for `pane_pid`, then writes both
`claude_pid` and its `claude_pid_start_time`; this gives tmux-backed cleanup the
same PID-reuse identity guard as headless `Hive::Agent` spawns.

Claude/tmux launches that use `status_mode: :output_file_exists` (reviewers, triage/browser helpers) poll the expected artifact and the managed tmux session together. If the session disappears before the expected file exists and is non-empty, `Hive::ClaudeLauncher` returns `status: :error` with `tmux_session_terminated...` instead of waiting for the full reviewer timeout. If the expected artifact is non-empty and Claude's Stop hook already wrote `.done`, the result is accepted as `:ok`; a non-empty artifact without `.done` is treated as partial and retried rather than being promoted as a successful review. Claude/tmux pane tails are also scanned for provider-limit UI such as Claude's "Stop and wait for limit to reset" / "Add funds to continue with usage credits" menu. When that appears, marker-owned waits stamp `ERROR reason=limits_reached` and expected-output waits return an error message beginning `limits reached for claude:` instead of surfacing generic readiness, timeout, or tmux-session-death errors.

`Hive::ClaudeLauncher.claude_ready_prompt?` treats Claude's TUI prompt as version-churny terminal chrome, not as a fixed last-line string. The detector keys on the idle `❯` caret only when it is the first or last glyph of its line, accepts Unicode separator spaces around it, and accepts the Claude Code 2.1.179 separator/caret/separator/footer shape as long as every line below the caret is prompt chrome or the real `bypass permissions` footer. It still rejects numbered menu options, current trust/permission prompts, stale carets with non-footer output below them, and `❯` glyphs embedded in Claude's own prose or shell snippets.

Claude/tmux teardown is deliberately narrower than a shell-pattern kill. `with_shared_session` first asks Claude to `/quit`, then kills the managed tmux session, then runs `sweep_orphan_processes(task)`. The sweep searches with `pgrep -fa -- "--add-dir[[:space:]]+<task.folder>([[:space:]]|$)"`, terminates matched non-tmux PIDs one by one with `TERM`, and skips any matched command whose executable basename is `tmux`. This matters because the tmux server can retain the first `tmux new-session ... --add-dir <task.folder> ...` argv; a blanket `pkill -f` would kill the tmux server and terminate unrelated live Hive sessions. The sweep appends the raw matches plus killed/skipped counts to `<task>/claude-tmux-orphan-sweep.log` (rotated at 64 KiB) and writes warning rows there when `pgrep` is missing or fails.

## `handle_exit`

| Condition | Marker set |
|-----------|------------|
| `result[:resource_exhaustion].reason == "token_limit"` | `<!-- ERROR reason=token_limit observed_tokens=N max_tokens=N marker_id=<hex16> -->` for `:state_file_marker`; other modes return the same error status without clobbering orchestrator-owned markers |
| `result[:resource_exhaustion].reason == "turn_limit"` | `<!-- ERROR reason=turn_limit observed_turns=N max_turns=N marker_id=<hex16> -->` for `:state_file_marker`; a completed output-file artifact is retained for downstream parsing |
| provider-limit text in a failed/timeout result's raw stream `limit_text` or `final_message` | `<!-- ERROR reason=limits_reached message="limits reached for <agent>: ..." marker_id=<hex16> -->` for `:state_file_marker`; other status modes return `result[:error_message] = "limits reached for <agent>: ..."` without clobbering orchestrator-owned markers |
| `result[:timed_out]` | `<!-- ERROR reason=timeout timeout_sec=N marker_id=<hex16> -->` |
| `exit_code` non-zero | `<!-- ERROR reason=exit_code exit_code=N marker_id=<hex16> -->` |
| `exit_code` is nil **and** marker is `:none` | `<!-- ERROR reason=no_marker_no_exit_code marker_id=<hex16> -->` (corrupted state, not silent OK) |
| Otherwise | `result[:status] = Markers.current(state_file).name` (trust the marker the agent wrote) |

`exit_code` can come back nil when claude streams large output and the parent's pipe-drain race loses the WNOHANG status; in that case we trust the marker the agent wrote. The nil-and-`:none` combination is treated as failure because a successful agent always writes a known marker.

## Why these three boundaries matter

The default Claude permission path still uses `--dangerously-skip-permissions` (`bypassPermissions`). Three controls keep this safe under the single-developer trust model:

1. **`--add-dir` discipline**: the agent only sees `cwd` and explicit `--add-dir` paths. Other projects on disk are unreachable.
2. **Status-mode ownership**: marker-owning stages use `:state_file_marker`; reviewer-style spawns can use `:output_file_exists` so the orchestrator, not the reviewer, owns terminal markers.
3. **Timeout + resource ceilings**: patrol passes a tier-specific `max_tokens` ceiling and clamps it to remaining cycle/day allowance; every spawn retains a wall-clock timeout. A profile-native USD-named flag is a budget-equivalent guard on subscription-backed providers, not evidence of an extra payment.

## Tests

- `test/unit/agent_test.rb` and `test/fixtures/fake-claude` exercise the spawn/wait/timeout logic without a real claude binary, including configurable permission argv, Claude model/effort and safe-mode `cli_flags`, proof that the capability is absent from unrelated launches, prompt omission from logs, credential redaction across stdout/stderr write boundaries, and `0600` log mode.
- `test/unit/claude_launcher_test.rb` covers the tmux wrapper argv carrying model/effort pins and omitting them when no flags are configured.
- `test/unit/spawn_agent_test.rb` covers `Stages::Base.spawn_agent` forwarding `claude.permission_mode` from config into headless Claude spawns and the stage permission-scope helper preserving yolo defaults.
- `test/smoke/permission_scope_headless_smoke_test.rb` is a live Claude smoke proving a read-only headless write attempt completes without timeout and does not create the file, while yolo creates it.

## Backlinks

- [[modules/task]] · [[modules/markers]] · [[modules/lock]]
- [[modules/agent_profile]] · [[modules/config]]
- [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/artifacts]] · [[stages/finalize]]
- [[architecture]]
