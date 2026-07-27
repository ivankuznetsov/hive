---
title: Hive::Agent
type: module
source: lib/hive/agent.rb, lib/hive/agent_runtime.rb, lib/hive/agent/message_extractor.rb, lib/hive/agent_limit.rb, lib/hive/claude_launcher.rb, lib/hive/scripts/interactive_claude_wrapper.sh
created: 2026-04-25
updated: 2026-07-27
tags: [agent, claude, subprocess]
---

**TLDR**: Agent subprocess wrapper. Sets `AGENT_WORKING` pre-spawn for
marker-owned spawns, parses bounded results/limits, enforces resource and
wall-clock ceilings, and translates exit through the selected AgentProfile
status mode. `:output_file_exists` now admits only non-empty regular in-root
artifacts through `Hive::ArtifactFirewall`; symlinks and directories cannot
satisfy completion.

For recognized built-in routing, `RoutingArguments.global_arguments` are
inserted before the profile headless subcommand and
`subcommand_arguments` after the common launch controls. Durable routed
implementation identities are rendered at the launcher seam for execute,
open-PR, review-fix, and review-CI, including Claude's headless/tmux adapter;
their deliberately empty legacy `native_arguments` array is never treated as
the complete routed command.

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
  expected_output: nil, # required regular artifact for :output_file_exists
  status_mode: nil,     # per-spawn override
  permission_mode: nil, # profile-owned override; nil uses profile default/config caller
  allowed_tools: nil,   # Claude-only --allowedTools CSV source
  disallowed_tools: nil,# Claude-only --disallowedTools CSV source
  cli_flags: [],        # per-run Claude argv extras (model/effort or verified capabilities)
  log_stream: true      # false parses the stream without retaining [stream] lines
)
```

## Constants

- `FINAL_MESSAGE_TAIL_BYTES = 64 * 1024` caps the plain stdout/stderr tail retained in `result[:final_message]` when no structured final agent message was parsed.
- Structured final messages use the same bound without masquerading a prefix
  as a complete provider result. If streamed chunks or one complete result
  exceed the cap, `final_message` is `nil`, `final_message_source` is
  `structured_truncated`, and `final_message_truncated` is true. A later
  coherent complete result within the bound replaces the stream and clears
  truncation.
- `TERMINATION_GRACE_SECONDS = 3` bounds graceful shutdown after a streamed token ceiling, completed-turn ceiling, or completed expected output before Hive escalates the process group to KILL.
- `COMPLETION_EVENT_GRACE_SECONDS = 3` lets an already-generated Claude `Write`
  and its usage-bearing turn delta settle in either event order; expiry or a
  next-turn start sends TERM, so the protocol allowance cannot become another
  reasoning turn.

## Provider-limit classification

`Hive::AgentLimit` is the shared classifier for provider account, rate, quota, billing, and usage-credit exhaustion. It normalizes ANSI/control-heavy terminal text before matching Claude's limit menu and common API error strings such as quota exhaustion, 429 too-many-requests responses, resource exhaustion, usage credits, and billing/limit language. The broad "limit reached/exceeded/reset" family is intentionally usage-qualified (`usage`, `rate`, `token`, `credit`, `quota`, account/subscription/time-window terms, etc.) so healthy agent output about UI limits such as scroll, window, viewport, page, buffer, or line limits does not trip a false `limits_reached` wall. `error_message(text, agent:)` prefixes the first useful normalized line with `limits reached` or `limits reached for <agent>`. `AgentLimit` also owns the periodic readiness interval: `RETRY_COOLDOWN_SEC` (default 3600s = 1h, overridable per-process via `HIVE_LIMITS_RETRY_COOLDOWN_SEC`, validated to a positive integer). `retry_after(text:, now:)` still preserves a complete provider reset estimate for status/TUI display, falling back to `now + cooldown`, but daemon scheduling deliberately ignores that estimate: `retry_due?` uses the latest quota marker's mtime so credits, usage resets, and account switches are noticed within one interval. See [[daemon]] and [[state-model]].

Headless `Hive::Agent#spawn_and_wait` scans each raw stream line for limit text while still preserving the structured final message and bounded plain tail. That raw-stream path catches CLIs that emit usage walls as JSON error events which `MessageExtractor` does not surface as a final assistant message; `handle_exit` then prefers `result[:limit_text]` and falls back to scanning `final_message`. The classifier still only controls failure/timeout handling: a clean `exit_code == 0` result is not reclassified. For `:state_file_marker` spawns it stamps `ERROR reason=limits_reached`; for `:exit_code_only` and `:output_file_exists` spawns it returns the limit message without overwriting the orchestrator-owned marker. `Hive::ClaudeLauncher` uses the same classifier while waiting for tmux readiness, terminal markers, and expected-output files, so a visible provider-limit pane wins over readiness timeout, tmux-session-death, and missing-output fallbacks.

Claude's own per-invocation cap has a separate protocol boundary.
`MessageExtractor.extract_failure` recognizes only a structured terminal
`type=result`, `subtype=error_max_budget_usd` event. It never infers failure
from ordinary assistant prose that happens to mention a budget. The headless
result exposes `failure_origin: "budget_exhausted"` plus bounded typed details:
provider, subtype, configured cap, observed cost when finite, diagnostic, and
the `raise_stage_budget` remedy. Marker-owned spawns write
`ERROR reason=budget_exhausted`; they do not write `limits_reached` or a
`retry_after`, so provider-quota recovery does not misclassify a stage whose
configured run cap is simply too low.

## `run!` (the main entry)

1. `ensure_log_dir`.
2. `Markers.set(state_file, :agent_working, pid: Process.pid, started: now)`.
3. `spawn_and_wait` — see below.
4. `handle_exit`: translate timeout / non-zero exit / missing-marker-after-clean-exit into the appropriate status/marker for the selected status mode.
5. Normalize the final Hash into immutable
   `AgentRuntime::ObservableResult`, available as `observable_result`.
6. Return the unchanged legacy result Hash.

There is **no inode-tracking concurrent-edit detection.** It was tried in early Phase 1 and removed — claude's own `Edit` and `Write` tools rewrite atomically (write tempfile + rename), changing the state file's inode every time. Inode mismatch was 100% false-positive. The current safety net for "user edits state file mid-run" is the documented "don't edit during AGENT_WORKING" rule plus the per-task `.lock` file's PID-liveness probe.

## `build_cmd`

`build_cmd` delegates a provider-neutral `AgentRuntime::Request` to
`AgentRuntime.compile`; it no longer assembles provider argv itself. The
selected `AgentProfile` remains the provider adapter:

```
<profile.bin> [<profile-routed global arguments>] <profile.headless_flag>
  <permission flags>
  [<profile.add_dir_flag> <dir> ...]
  [--allowedTools <csv>]
  [--disallowedTools <csv>]
  [<profile.budget_flag> <amount>]
  [<cli_flags...>]
  <profile.output_format_flags...>
  <prompt>
```

In actual argv the binary remains first: profile-routed global arguments are
inserted immediately after it and before the headless subcommand. This is an
opt-in path used only for an active recognized `ModelRouting` resolution.
Codex therefore receives `codex --model ... -c
model_reasoning_effort=... exec ...`; Claude, Grok, and Pi keep their
profile-native routed arguments in the subcommand segment. Unscoped calls and
inactive resolutions stay on the original assembly path, including the
existing flat implementation-identity argument position.

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
`disallowed_tools:` are emitted only when the profile declares the corresponding
`tool_scope_flags` (currently Claude) and only when
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

Read-only architecture discovery is a separate Claude-only launch policy.
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
7. Reader thread: the shared stdout/stderr pipe is line-buffered before persistence, so credentials split across provider writes or the two streams are reassembled before `Hive::SecretPatterns.redact` runs. Structured message-bearing JSON events are stricter: their payload is omitted from the durable log and replaced with event-type metadata because one logical credential can span multiple newline-delimited events. Timestamped `[stream]` lines are retained only when `log_stream` is true, but raw in-memory lines feed structured final-message parsing, structured Claude failure extraction, provider-limit detection, usage, turns, and expected-output completion after protocol-specific opacity filtering. A shared `MessageExtractor::Accumulator` keeps both streaming structured messages and the plain fallback within 64 KiB; byte-bounded plain-tail truncation drops any partial UTF-8 character at the cut so fallback messages remain valid text. Claude-style `result` / `assistant` events and Codex-style `item.completed` assistant messages set `result[:final_message_source] = :structured`. A profile must explicitly declare `structured_output_protocol: :grok_end` before a Hash-valued Grok terminal `end.structuredOutput` payload gains the same authority; custom and non-Grok profiles ignore that event shape. A valid Grok terminal schema result replaces its preceding human-readable stream. In a managed host-output run, a non-Hash or conservatively recognized unparseable terminal payload sets `final_message_source = :structured_invalid`, clears preceding output, and makes publication fail closed; an ordinary unstructured Grok run preserves its preceding prose instead. Parsed and unparseable Grok terminal payloads are omitted from durable logs and plain fallback, and are excluded from raw quota scanning so private output cannot become `limit_text`. Display-name generation uses the same profile-declared protocol accumulator without managed strictness. When `max_tokens` is set, `StreamTokenMeter` also converts usage events into one monotonic count. Claude message-start/delta events sum completed turns while maxing cumulative current-turn fields; terminal run totals replace the aggregate only when they are not smaller than already observed usage. The digest generator sets `log_stream: false` because provider output may reflect confidential repository evidence; its spawn breadcrumb remains, while stream lines are not retained.
8. Polling loop: `Process.wait(pid, WNOHANG)` every `[remaining, 0.2].min` seconds until the deadline. Reaching `max_tokens`, reaching the Claude `max_turns` ceiling, or observing a non-empty expected output begins termination. Claude can emit its local `Write` result before or after the same turn's usage-bearing `message_delta`, so Hive waits at most the completion-event grace for the missing half, captures the delta when available, and sends TERM before a next model turn. A process group still alive after the termination grace receives KILL independently of the longer wall-clock timeout.
9. On timeout: `kill_group(pgid)` (TERM), then `sleep_grace_then_kill` (3s grace, then KILL).
10. Reap with `Process.wait(pid)` (rescuing `Errno::ECHILD`).
11. Join the reader thread (kill if still alive after 2s).
12. Return `{pid, pgid, exit_code, timed_out, log_file, final_message, final_message_source, usage, resource_exhaustion, output_completed, status: nil}` plus `failure_origin` / `failure_details` only when a recognized structured failure was observed. Resource exhaustion carries `reason: "token_limit"` or `"turn_limit"`, the configured limit, and the observed count. A completed output is accepted only in `:output_file_exists` mode, must pass the Artifact Firewall's non-empty regular-file/root admission, and remains subject to the caller's structured parser.

`final_message` is for orchestrators that need a human-readable agent answer even when the agent does not edit the state file. 4-execute writes this into `task.md` under `## Execute Output`; only structured final messages satisfy research-mode completion.

Claude/tmux launches record the managed pane PID in the same per-task lock.
`Hive::ClaudeLauncher#record_claude_pid` waits for `pane_pid`, then writes both
`claude_pid` and its `claude_pid_start_time`; this gives tmux-backed cleanup the
same PID-reuse identity guard as headless `Hive::Agent` spawns.

Claude/tmux launches that use `status_mode: :output_file_exists` (reviewers,
triage/browser helpers) poll the expected artifact and managed tmux session
together. Availability means a non-empty regular file accepted by
`ArtifactFirewall.validate_required_outputs`; a symlink or directory remains
unavailable even when its target has bytes. If the session disappears before
acceptance, the launcher returns `tmux_session_terminated...`. An accepted
artifact still needs Claude's Stop hook `.done` or a proven ready prompt;
otherwise it remains partial. Provider-limit pane evidence continues to win
over readiness, timeout, session-death, and missing-output fallbacks.

`Hive::ClaudeLauncher.claude_ready_prompt?` treats Claude's TUI prompt as version-churny terminal chrome, not as a fixed last-line string. The detector keys on the idle `❯` caret only when it is the first or last glyph of its line, accepts Unicode separator spaces around it, and accepts the Claude Code 2.1.179 separator/caret/separator/footer shape as long as every line below the caret is prompt chrome or the real `bypass permissions` footer. It still rejects numbered menu options, current trust/permission prompts, stale carets with non-footer output below them, and `❯` glyphs embedded in Claude's own prose or shell snippets.

Claude/tmux teardown is deliberately narrower than a shell-pattern kill. `with_shared_session` first asks Claude to `/quit`, then kills the managed tmux session, then runs `sweep_orphan_processes(task)`. The sweep searches with `pgrep -fa -- "--add-dir[[:space:]]+<task.folder>([[:space:]]|$)"`, terminates matched non-tmux PIDs one by one with `TERM`, and skips any matched command whose executable basename is `tmux`. This matters because the tmux server can retain the first `tmux new-session ... --add-dir <task.folder> ...` argv; a blanket `pkill -f` would kill the tmux server and terminate unrelated live Hive sessions. The sweep appends the raw matches plus killed/skipped counts to `<task>/claude-tmux-orphan-sweep.log` (rotated at 64 KiB) and writes warning rows there when `pgrep` is missing or fails.

## `handle_exit`

| Condition | Marker set |
|-----------|------------|
| `result[:resource_exhaustion].reason == "token_limit"` | `<!-- ERROR reason=token_limit observed_tokens=N max_tokens=N marker_id=<hex16> -->` for `:state_file_marker`; other modes return the same error status without clobbering orchestrator-owned markers |
| `result[:resource_exhaustion].reason == "turn_limit"` | `<!-- ERROR reason=turn_limit observed_turns=N max_turns=N marker_id=<hex16> -->` for `:state_file_marker`; a completed output-file artifact is retained for downstream parsing |
| `result[:failure_origin] == "budget_exhausted"` | A current non-empty state artifact ending in `WAITING` or a terminal marker wins over a trailing budget diagnostic; otherwise `<!-- ERROR reason=budget_exhausted provider=claude subtype=error_max_budget_usd max_budget_usd=N observed_cost_usd=N remedy=raise_stage_budget marker_id=<hex16> -->` for `:state_file_marker`, or the same typed error result without clobbering another status mode's marker |
| provider-limit text in a failed/timeout result's raw stream `limit_text` or `final_message` | `<!-- ERROR reason=limits_reached message="limits reached for <agent>: ..." marker_id=<hex16> -->` for `:state_file_marker`; other status modes return `result[:error_message] = "limits reached for <agent>: ..."` without clobbering orchestrator-owned markers |
| `result[:timed_out]` | `<!-- ERROR reason=timeout timeout_sec=N marker_id=<hex16> -->` |
| `exit_code` non-zero | `<!-- ERROR reason=exit_code exit_code=N marker_id=<hex16> -->` |
| `exit_code` is nil **and** marker is `:none` | `<!-- ERROR reason=no_marker_no_exit_code marker_id=<hex16> -->` (corrupted state, not silent OK) |
| Otherwise | `result[:status] = Markers.current(state_file).name` (trust the marker the agent wrote) |

`exit_code` can come back nil when claude streams large output and the parent's pipe-drain race loses the WNOHANG status; in that case we trust the marker the agent wrote. The nil-and-`:none` combination is treated as failure because a successful agent always writes a known marker. The generic completed-artifact precedence is intentionally structural only at the Agent layer; stages such as Brainstorm apply their stricter artifact validation before accepting the outcome.

## Why these three boundaries matter

The default Claude permission path still uses `--dangerously-skip-permissions` (`bypassPermissions`). Three controls keep this safe under the single-developer trust model:

1. **`--add-dir` discipline**: the agent only sees `cwd` and explicit `--add-dir` paths. Other projects on disk are unreachable.
2. **Status-mode ownership**: marker-owning stages use `:state_file_marker`; reviewer-style spawns can use `:output_file_exists` so the orchestrator, not the reviewer, owns terminal markers.
3. **Timeout + resource ceilings**: patrol passes a tier-specific `max_tokens` ceiling and clamps it to remaining cycle/day allowance; every spawn retains a wall-clock timeout. A profile-native USD-named flag is a budget-equivalent guard on subscription-backed providers, not evidence of an extra payment.

## Tests

- `test/unit/agent_test.rb` and `test/fixtures/fake-claude` exercise the spawn/wait/timeout logic without a real claude binary, including configurable permission argv, Claude model/effort and safe-mode `cli_flags`, proof that the capability is absent from unrelated launches, prompt omission from logs, credential redaction across stdout/stderr write boundaries and structured message-event boundaries, and `0600` log mode.
- `test/unit/claude_launcher_test.rb` covers the tmux wrapper argv carrying model/effort pins and omitting them when no flags are configured.
- `test/unit/spawn_agent_test.rb` covers `Stages::Base.spawn_agent` forwarding `claude.permission_mode` from config into headless Claude spawns and the stage permission-scope helper preserving yolo defaults.
- `test/smoke/permission_scope_headless_smoke_test.rb` is a live Claude smoke proving a read-only headless write attempt completes without timeout and does not create the file, while yolo creates it.

## Backlinks

- [[modules/task]] · [[modules/markers]] · [[modules/lock]]
- [[modules/agent_profile]] · [[modules/protected_files]] · [[modules/config]]
- [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/artifacts]] · [[stages/finalize]]
- [[architecture]]
