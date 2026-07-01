---
title: 2-brainstorm stage
type: stage
source: lib/hive/stages/brainstorm.rb, lib/hive/stages/brainstorm_tmux.rb, lib/hive/tmux_runner.rb, templates/brainstorm_prompt.md.erb
created: 2026-04-25
updated: 2026-06-16
tags: [stage, brainstorm, qa, tmux]
---

**TLDR**: Round-by-round Q&A. Agent reads `idea.md`, writes `brainstorm.md` with `## Round N` questions and a `<!-- WAITING -->` marker. User answers inline. Re-running the stage parses answers and either appends `## Round N+1` or finalises with `## Requirements` and `<!-- COMPLETE -->`. When the resolved `brainstorm.agent` is Claude, launch shape comes from project-global `claude.mode`: `tmux` runs Claude inside a managed attachable tmux session via `Hive::ClaudeLauncher`, while `headless` uses the normal non-interactive profile path. Legacy `brainstorm.runtime` is still read only when `claude.mode` is absent, and `hive doctor` advises migrating it.

## Setup

- **State file**: `brainstorm.md` (touched empty if absent so the marker write has a target).
- **Prompt**: `templates/brainstorm_prompt.md.erb`, rendered with `project_name`, `task_folder`, `idea_text`. Idea text is wrapped in `<user_supplied content_type="idea_text">…</user_supplied>` per the prompt-injection boundary policy.
- **Agent invocation**: `cwd = task.folder`, `--add-dir <task.folder>`, `log_label = "brainstorm"`. For `claude.mode: tmux`, `Hive::ClaudeLauncher` starts Claude through `interactive_claude_wrapper.sh`, unsets API-key env vars, maps `claude.permission_mode` (default `bypassPermissions`) to the same flags the headless path uses (`bypassPermissions` → `--dangerously-skip-permissions`, otherwise `--permission-mode <mode>`) plus `--allowedTools Read,Write,Edit,LS`, waits for the TUI prompt, and then asks `Hive::TmuxRunner` to paste the rendered prompt and submit only after the pane tail has settled.
- **Tmux readiness env vars**: `Hive::ClaudeLauncher` owns `HIVE_CLAUDE_TMUX_*` readiness settings. `SESSION_READY`, `PID_READY`, and `CLAUDE_READY` inherit `HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC` when their specific env var is unset; `CLAUDE_READY` otherwise keeps a 120s bare default for slow Claude TUI startup. Legacy `HIVE_BRAINSTORM_TMUX_*` names remain fallback inputs during the migration window.
- **Claude TUI readiness predicates**: Trust and ready strings are named constants in `Hive::ClaudeLauncher`, pinned to the Claude Code 2.1.133 TUI observed during the 2026-05-25 tmux dogfood. `claude_ready_prompt?` accepts the idle caret at the bottom of the input box with the current Claude footer, including the patrol-observed case where the captured pane tail has scrolled the `Claude Code` banner out but still shows `... PR #N ... for agents`; it classifies trust and permission prompts from the current prompt block instead of stale scrollback, and rejects numbered menu options as non-ready.
- **Tmux submit/session failures**: `Hive::TmuxRunner#send_prompt` loads and pastes the prompt through a tmux buffer, waits until the pane tail is identical across two consecutive captures (`PROMPT_SETTLE_STABLE_POLLS`) or the bounded `HIVE_TMUX_PROMPT_SETTLE_TIMEOUT_SEC` deadline passes, then sends one explicit Enter. `HIVE_TMUX_PROMPT_SUBMIT_DELAY_SEC` is the poll interval. This avoids the old large-paste race where Enter could fire while a multi-chunk prompt was still rendering and be swallowed by the input box. If tmux disappears before that Enter submit or a tmux command exceeds `HIVE_TMUX_COMMAND_TIMEOUT_SEC`, the typed tmux error propagates immediately. During marker polling, `Hive::ClaudeLauncher.wait_for_terminal_marker` also checks that the tmux session still exists while `brainstorm.md` is stuck on `AGENT_WORKING`; a disappeared session stamps `ERROR reason=tmux_session_terminated` instead of waiting for the full brainstorm timeout.
- **Tmux cleanup/orphan sweep**: cleanup is shared in `Hive::ClaudeLauncher`. After `/quit` and `kill_session`, the launcher sweeps leftover Claude processes by this task's `--add-dir <task.folder>` while skipping matched `tmux` commands and logging killed/skipped entries to `claude-tmux-orphan-sweep.log`. The skip is load-bearing because the tmux server can keep the first session's full argv and would otherwise match the task-specific sweep pattern.
- **Profile**: `Hive::Stages::Base.stage_profile(cfg, "brainstorm")` — reads `cfg.dig("brainstorm", "agent")` with `|| "claude"` fallback so legacy configs keep working. Spawn pins `status_mode: :state_file_marker` regardless of profile, because brainstorm's lifecycle contract is the WAITING/COMPLETE marker the agent writes to `brainstorm.md` — codex's profile default `:output_file_exists` would never satisfy that.
- **Budgets**: `cfg["budget_usd"]["brainstorm"]` (default 50), `cfg["timeout_sec"]["brainstorm"]` (default 1800). Bumped ~5× in plan 2026-05-04-001 — generous sanity caps for runaway agents, not cost targets.

## Agent behaviour (per `templates/brainstorm_prompt.md.erb`)

1. If `brainstorm.md` is empty/missing, read `idea.md` and produce **Round 1** as a Q&A block:
   ```
   ## Round 1
   ### Q1. <question>
   ### A1.
   ### Q2. <question>
   ### A2.
   ```
   End with `<!-- WAITING -->`.
2. If `brainstorm.md` already has rounds, parse the most recent `## Round N`. If all answers are filled in, append `## Requirements` (actor / flow / acceptance examples) and end with `<!-- COMPLETE -->`. Otherwise append `## Round N+1` with follow-ups and end with `<!-- WAITING -->`.
3. Use `/ce-brainstorm` skill where available. Legacy `compound-engineering:ce-*` config values are normalized before rendering.

Agent must not modify any file other than `brainstorm.md` and must not run shell or network tools.

## Marker → commit action mapping (`Stages::Brainstorm.action_for`)

| Marker | Commit action |
|--------|---------------|
| `:waiting` | `round_waiting` |
| `:complete` | `complete` |
| `:error` | `error` |
| (other) | `<marker>.to_s` |

The runner returns `{commit: action, status: marker.name}` so `Commands::Run` writes a `hive: 2-brainstorm/<slug> <action>` commit on `hive/state`.

## Tests

- `test/integration/run_brainstorm_test.rb` exercises the prompt shape and marker transitions using the fake-claude fixture.
- `test/integration/run_brainstorm_tmux_test.rb` exercises the tmux launcher path.
- `test/unit/stages/brainstorm_tmux_sentinel_test.rb` pins the tmux readiness/sentinel helpers and the orphan-sweep invariant that matched Claude PIDs are terminated individually while the tmux server is skipped and logged.
- `test/unit/tmux_runner_test.rb` pins prompt-buffer cleanup, tmux command timeouts, and paste-settle behavior before the final Enter submit.

## Backlinks

- [[stages/inbox]] · [[stages/plan]]
- [[modules/agent]] · [[modules/markers]]
- [[state-model]]
