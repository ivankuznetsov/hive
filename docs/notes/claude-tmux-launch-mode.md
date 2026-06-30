# Claude Tmux Launch Mode

**Status:** project-global Claude launch mode
**Config:** `claude.mode: tmux`, `claude.permission_mode: bypassPermissions` by default

## Why this exists

The headless Claude path uses Hive's normal non-interactive agent spawn:
`claude -p ... <prompt>`. That is deterministic and CI-friendly, but a
Claude Code headless `-p` invocation can bill against API-token usage.

The tmux mode starts an interactive `claude` process inside a managed tmux
session instead. Because the wrapper unsets
`ANTHROPIC_API_KEY` and `CLAUDE_API_KEY`, Claude Code uses the operator's
logged-in OAuth/subscription auth rather than API-key billing. Hive waits
until Claude's TUI is ready before pasting the stage prompt; if Claude
shows its first-run folder-trust prompt, Hive confirms it for the task
folder and then waits for the normal prompt.

The trust and ready predicates are pinned in `Hive::ClaudeLauncher` against the
Claude Code 2.1.133 TUI observed during the 2026-05-25 dogfood, and
ready detection requires the prompt marker on the last non-blank pane line,
classifies trust and permission prompts from the current prompt block instead of
stale scrollback, and rejects numbered menu options as non-ready.

## Scope

The project-global setting applies only when the resolved agent profile is
Claude:

- `2-brainstorm`, `3-plan`, `4-execute`, `5-open-pr`, `7-artifacts`,
  `8-finalize`, and Claude sub-spawns inside `6-review`;
- non-Claude profiles such as Codex and Pi keep the normal headless path;
- no automatic fallback to headless when tmux is missing;
- no per-stage override.

Session names are deterministic, for example `hive-4-execute-<slug>` or
`hive-6-review-pass1-<slug>`. Operators can attach while a stage is running:

```sh
tmux attach -t hive-4-execute-<slug>
```

## Control Signals

The terminal state is still the last marker in the stage state file:

- `<!-- WAITING -->` means another Q&A round is ready for the user;
- `<!-- COMPLETE -->` means brainstorm is ready to advance;
- `<!-- ERROR ... -->` means the stage failed and normal recovery applies.

The Stop hook writes two sibling files in the orchestrator-owned task
folder, even when Claude's process cwd is the feature worktree:

- `.done` tells Hive that an interactive Claude turn ended;
- `result.json` keeps the raw hook payload for forensics.

For marker-owned stages, `.done` is only a wake-up event. On every wake-up,
Hive re-reads the stage file; if the marker is still non-terminal, `.done`
is deleted and the watchdog keeps waiting. For `:exit_code_only` spawns
such as review-fix, Hive reads `result.json` and treats `ok`, `complete`,
or `success` as a clean exit. The path contract is pinned in
`test/unit/stop_hook_installer_test.rb`: `StopHookInstaller` installs
`.claude/settings.json` under both the task folder and launch cwd, but
both copies set `HIVE_TASK_STAGE_DIR` to the task folder, which matches
`ClaudeLauncher.done_path` and `ClaudeLauncher.result_path`.

The wrapper resolves `claude.permission_mode` (default `bypassPermissions`)
to the same CLI flags the headless `-p` path uses: `bypassPermissions` becomes
`--dangerously-skip-permissions`, and any other mode becomes
`--permission-mode <mode>`. It also passes an explicit `--allowedTools
Read,Write,Edit,LS` list so ordinary task-folder reads and stage-file writes
do not stop on permission prompts. Projects can set
`claude.permission_mode: auto` to use Claude Code auto-mode rules instead.
This does not turn brainstorm into a shell-execution stage; Bash is not in
the allowed tool list, and the prompt still instructs Claude to modify only
`brainstorm.md` and not to invoke shell/network tools.

## Failure Modes

- **Stop hook does not fire:** Hive periodically captures the pane tail.
  For marker-owned waits, it only exits if the pane shows a terminal marker
  and the stage file has the same terminal marker. For `:exit_code_only`
  waits, Hive attaches conservative completion evidence to the timeout
  result when the pane has returned to Claude's idle prompt or the recorded
  Claude PID has exited. Review-fix can accept that evidence only when its
  own artifacts and commit/no-change checks also pass.
- **Pane crashes:** no terminal marker appears, so the existing brainstorm
  timeout applies and Hive writes `<!-- ERROR reason=timeout ... -->`.
- **Duplicate session name:** Hive refuses to start a second pane and tells
  the operator which session already exists.
- **Missing tmux or old tmux:** preflight requires `tmux >= 3.0`; `hive
  doctor` reports this dependency when `claude.mode` is `tmux`.
- **API key present in parent shell:** the wrapper clears
  `ANTHROPIC_API_KEY` and `CLAUDE_API_KEY` before `exec claude`.
- **Claude prompt not ready yet:** Hive polls the pane tail for the
  interactive Claude prompt before pasting. This avoids losing the prompt
  into the folder-trust screen or submitting before Claude's input box is
  ready.

## Stop-Hook Signaling Finding

The production failure investigated on 2026-06-30 was isolated to
interactive tmux `:exit_code_only` waits, especially review-fix: Claude
finished its turn and the worktree/artifacts were complete, but
`result.json` and `.done` never appeared before the wait deadline. The
most likely root cause is Claude Code interactive REPL Stop-hook delivery
being absent or late for some turn completions. The alternative causes
checked in code were path drift (`StopHookInstaller` now installs in both
task folder and cwd while pointing both at the task folder), script write
ordering (`stop_hook.sh` writes `result.json` before touching `.done`),
and cleanup races (`reset_signal_files` runs before launch and cleanup runs
after session teardown). No deterministic local reproduction was found, so
the shipped fix is a conservative fallback in `ClaudeLauncher` plus
review-fix phase evidence checks rather than a speculative hook rewrite.

## Teardown

`ClaudeLauncher` kills the tmux session in an `ensure` block, removes the
per-task `.claude/settings.json`, deletes stale `.done`, and runs a narrow
`pkill -f` sweep scoped to the task folder's `--add-dir` argument.
The sweep is defensive; normal cleanup is tmux session termination.

## Runtime Tunables

The integration tests pin these to short intervals; operators debugging
the runtime can override them in the calling shell:

- `HIVE_CLAUDE_TMUX_POLL_INTERVAL_SEC` (default `0.5`) — how often the
  `.done` watchdog wakes to re-read the marker.
- `HIVE_CLAUDE_TMUX_SENTINEL_INTERVAL_SEC` (default `5`) — how often
  Hive captures the pane tail as a fallback when the Stop hook does not
  fire.
- `HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC` (default `5`) — shared
  override for the readiness waits below when their specific env vars
  are unset. Override one of them directly to tune that wait without
  affecting the others.
- `HIVE_CLAUDE_TMUX_SESSION_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC`) — budget for tmux session creation
  after `new-session -d`.
- `HIVE_CLAUDE_TMUX_PID_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC`) — budget for the claude PID to appear
  in the pane after the wrapper execs.
- `HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC` when set, otherwise `120`) — budget
  for the Claude interactive prompt to become ready after the tmux
  session starts.
- `HIVE_TMUX_PROMPT_SUBMIT_DELAY_SEC` (default `0.2`) — delay between
  pasting the prompt into tmux and pressing Enter. Claude Code processes
  large bracketed pastes asynchronously, so a short delay prevents Enter
  from racing ahead of the pasted prompt.
  If tmux disappears before the explicit Enter submit, `TmuxRunner#send_prompt`
  raises the typed tmux failure immediately rather than waiting for the stage
  timeout.
- `HIVE_TMUX_COMMAND_TIMEOUT_SEC` (default `10.0`) — per-tmux-command
  wall-clock guard. A wedged tmux client is killed and surfaced as a typed
  timeout error instead of bypassing the stage timeout.
- `HIVE_TMUX_BIN` (default `tmux`) — override the tmux executable path,
  e.g., to point at a homebrew-installed binary on macOS.
- `HIVE_TMUX_SOCKET` — optional `-L` socket name, used by integration
  tests to keep their sessions off the operator's default tmux server.

Legacy `HIVE_BRAINSTORM_TMUX_*` names are still honored as fallbacks for
one release while projects migrate from the old brainstorm-only runtime.
