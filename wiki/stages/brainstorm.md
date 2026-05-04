---
title: 2-brainstorm stage
type: stage
source: lib/hive/stages/brainstorm.rb, templates/brainstorm_prompt.md.erb
created: 2026-04-25
updated: 2026-04-25
tags: [stage, brainstorm, qa]
---

**TLDR**: Round-by-round Q&A. Agent reads `idea.md`, writes `brainstorm.md` with `## Round N` questions and a `<!-- WAITING -->` marker. User answers inline. Re-running the stage parses answers and either appends `## Round N+1` or finalises with `## Requirements` and `<!-- COMPLETE -->`.

## Setup

- **State file**: `brainstorm.md` (touched empty if absent so the marker write has a target).
- **Prompt**: `templates/brainstorm_prompt.md.erb`, rendered with `project_name`, `task_folder`, `idea_text`. Idea text is wrapped in `<user_supplied content_type="idea_text">…</user_supplied>` per the prompt-injection boundary policy.
- **Agent invocation**: `cwd = task.folder`, `--add-dir <project_root>` (so `claude` picks up the project's `CLAUDE.md` / `.claude/`), `log_label = "brainstorm"`.
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
3. Use `/compound-engineering:ce-brainstorm` skill where available.

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

## Backlinks

- [[stages/inbox]] · [[stages/plan]]
- [[modules/agent]] · [[modules/markers]]
- [[state-model]]
