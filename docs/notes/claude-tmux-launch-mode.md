# Claude Tmux Launch Mode

**Status:** project-global Claude launch mode
**Config:** `claude.mode: tmux`

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

The Stop hook writes two sibling files in the task folder:

- `.done` tells Hive that an interactive Claude turn ended;
- `result.json` keeps the raw hook payload for forensics.

`.done` is only a wake-up event. On every wake-up, Hive re-reads
the stage file; if the marker is still non-terminal, `.done` is deleted
and the watchdog keeps waiting. This preserves the manual-intervention
model: a human may type in the attached pane, but completion still requires
Claude to write the expected terminal marker.

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
  doctor` reports this dependency when `claude.mode` is `tmux`.
- **API key present in parent shell:** the wrapper clears
  `ANTHROPIC_API_KEY` and `CLAUDE_API_KEY` before `exec claude`.
- **Claude prompt not ready yet:** Hive polls the pane tail for the
  interactive Claude prompt before pasting. This avoids losing the prompt
  into the folder-trust screen or submitting before Claude's input box is
  ready.

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
  default for the two ready-waits below. Override one of them directly
  to tune that wait without affecting the other.
- `HIVE_CLAUDE_TMUX_SESSION_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC`) — budget for tmux session creation
  after `new-session -d`.
- `HIVE_CLAUDE_TMUX_PID_READY_WAIT_TIMEOUT_SEC` (defaults to the
  shared `READY_WAIT_TIMEOUT_SEC`) — budget for the claude PID to appear
  in the pane after the wrapper execs.
- `HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC` (default `30`) —
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

Legacy `HIVE_BRAINSTORM_TMUX_*` names are still honored as fallbacks for
one release while projects migrate from the old brainstorm-only runtime.
