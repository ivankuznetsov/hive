# Brainstorm Interactive Tmux Runtime

**Status:** opt-in, brainstorm-only
**Config:** `brainstorm.runtime: tmux_interactive`

## Why this exists

The default brainstorm runtime uses Hive's normal headless agent path:
`claude -p ... <prompt>`. That is deterministic and CI-friendly, but a
Claude Code headless `-p` invocation can bill against API-token usage.

The tmux runtime starts a normal interactive `claude` process inside a
per-task tmux session instead. Because the wrapper unsets
`ANTHROPIC_API_KEY` and `CLAUDE_API_KEY`, Claude Code uses the operator's
logged-in OAuth/subscription auth rather than API-key billing.

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

## Teardown

`BrainstormTmux.run!` kills the tmux session in an `ensure` block, removes
the per-task `.claude/settings.json`, deletes stale `.done`, and runs a
narrow `pkill -f` sweep scoped to the task folder's `--add-dir` argument.
The sweep is defensive; normal cleanup is tmux session termination.
