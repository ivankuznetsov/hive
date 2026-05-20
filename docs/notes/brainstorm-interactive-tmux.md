# Brainstorm Interactive Tmux Runtime

**Status:** opt-in, brainstorm-only
**Config:** `brainstorm.runtime: tmux_interactive`

## Why this exists

The default brainstorm runtime uses Hive's normal headless agent path:
`claude -p ... <prompt>`. That is deterministic and CI-friendly, but a
Claude Code headless `-p` invocation can bill against API-token usage.

The tmux runtime starts an interactive `claude` process inside a
per-task tmux session instead. Because the wrapper unsets
`ANTHROPIC_API_KEY` and `CLAUDE_API_KEY`, Claude Code uses the operator's
logged-in OAuth/subscription auth rather than API-key billing. Hive waits
until Claude's TUI is ready before pasting the brainstorm prompt; if Claude
shows its first-run folder-trust prompt, Hive confirms it for the task
folder and then waits for the normal prompt.

## Scope

This runtime is intentionally narrow:

- stage `2-brainstorm` only;
- one fresh tmux session per task;
- no session reuse, warm pool, or cross-stage context carryover;
- no changes to `Hive::Agent` or other stages;
- default remains `headless`.

The session name is deterministic: `hive-2-brainstorm-<slug>`. Operators
can attach while a brainstorm is running:

```sh
tmux attach -t hive-2-brainstorm-<slug>
```

## Control Signals

The terminal state is still the last marker in `brainstorm.md`:

- `<!-- WAITING -->` means another Q&A round is ready for the user;
- `<!-- COMPLETE -->` means brainstorm is ready to advance;
- `<!-- ERROR ... -->` means the stage failed and normal recovery applies.

The Stop hook writes two sibling files in the task folder:

- `.done` tells Hive that an interactive Claude turn ended;
- `result.json` keeps the raw hook payload for forensics.

`.done` is only a wake-up event. On every wake-up, Hive re-reads
`brainstorm.md`; if the marker is still non-terminal, `.done` is deleted
and the watchdog keeps waiting. This preserves the manual-intervention
model: a human may type in the attached pane, but completion still requires
Claude to write a terminal marker to `brainstorm.md`.

The wrapper starts Claude with `--permission-mode bypassPermissions` and an
explicit `--allowedTools Read,Write,Edit,LS` list so ordinary task-folder
reads and `brainstorm.md` writes do not stop on permission prompts. This
does not turn brainstorm into a shell-execution stage; Bash is not in the
allowed tool list, and the prompt still instructs Claude to modify only
`brainstorm.md` and not to invoke shell/network tools.

## Failure Modes

- **Stop hook does not fire:** Hive periodically captures the pane tail.
  It only exits if the pane shows a terminal marker and `brainstorm.md`
  has the same terminal marker.
- **Pane crashes:** no terminal marker appears, so the existing brainstorm
  timeout applies and Hive writes `<!-- ERROR reason=timeout ... -->`.
- **Duplicate session name:** Hive refuses to start a second pane and tells
  the operator which session already exists.
- **Missing tmux or old tmux:** preflight requires `tmux >= 3.0`; `hive
  doctor` reports this dependency when `brainstorm.runtime` is
  `tmux_interactive`.
- **API key present in parent shell:** the wrapper clears
  `ANTHROPIC_API_KEY` and `CLAUDE_API_KEY` before `exec claude`.
- **Claude prompt not ready yet:** Hive polls the pane tail for the
  interactive Claude prompt before pasting. This avoids losing the prompt
  into the folder-trust screen or submitting before Claude's input box is
  ready.

## Teardown

`BrainstormTmux.run!` kills the tmux session in an `ensure` block, removes
the per-task `.claude/settings.json`, deletes stale `.done`, and runs a
narrow `pkill -f` sweep scoped to the task folder's `--add-dir` argument.
The sweep is defensive; normal cleanup is tmux session termination.

## Runtime Tunables

The integration tests pin these to short intervals; operators debugging
the runtime can override them in the calling shell:

- `HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC` (default `0.5`) — how often the
  `.done` watchdog wakes to re-read the marker.
- `HIVE_BRAINSTORM_TMUX_SENTINEL_INTERVAL_SEC` (default `5`) — how often
  Hive captures the pane tail as a fallback when the Stop hook does not
  fire.
- `HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC` (default `5`) — shared
  default for the two ready-waits below. Override one of them directly
  to tune that wait without affecting the other.
- `HIVE_BRAINSTORM_TMUX_SESSION_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC`) — budget for tmux session creation
  after `new-session -d`.
- `HIVE_BRAINSTORM_TMUX_PID_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC`) — budget for the claude PID to appear
  in the pane after the wrapper execs.
- `HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC` (default `30`) —
  budget for Claude's interactive prompt to become ready after the tmux
  session starts.
- `HIVE_TMUX_PROMPT_SUBMIT_DELAY_SEC` (default `0.2`) — delay between
  pasting the prompt into tmux and pressing Enter. Claude Code processes
  large bracketed pastes asynchronously, so a short delay prevents Enter
  from racing ahead of the pasted prompt.
- `HIVE_TMUX_BIN` (default `tmux`) — override the tmux executable path,
  e.g., to point at a homebrew-installed binary on macOS.
- `HIVE_TMUX_SOCKET` — optional `-L` socket name, used by integration
  tests to keep their sessions off the operator's default tmux server.
