---
title: Generic Agent Stage Runner
type: stage
source: lib/hive/stages/agent.rb, templates/agent_prompt.md.erb
created: 2026-06-19
updated: 2026-06-20
tags: [stage, agent, workflow]
---

**TLDR**: `Hive::Stages::Agent` is the shared headless runner for descriptor
stages whose `kind` is `:agent` and whose name does not already have a bespoke
coding runner. `Hive::Stages::Resolver` reaches it as the fallback after the
coding-name runner table. The runner resolves the active stage per-task via
`task.workflow.stage_named(task.stage_name)` (the core U6 generic behavior — NOT
the coding-pinned `Hive::Workflows::Registry.default`), renders
`templates/agent_prompt.md.erb`, spawns one folder-isolated agent, and maps the
resulting state-file marker to the same commit actions as [[stages/brainstorm]].

## Runtime Contract

1. Resolve the stage descriptor by `task.stage_name`.
2. Use `stage.state_file` as the output and marker file.
3. Build prior context from sorted `*.md` files in the task folder, excluding the
   stage's own output file. The context is capped at 8000 characters. Each file
   read is rescued individually, so one unreadable/race-deleted artifact degrades
   to a placeholder rather than aborting the run.
4. Wrap prior context in a fresh `Hive::Stages::Base.user_supplied_tag` nonce so
   prior artifacts are treated as untrusted input.
5. Use `stage.skill` through `profile.format_skill_invocation` when present;
   otherwise use the generic "produce the best stage output" instruction.
6. Spawn via `Hive::Stages::Base.spawn_agent` with `add_dirs: [task.folder]`,
   `cwd: task.folder`, the descriptor's `status_mode` (falling back to
   `:state_file_marker` only when unset), a `timeout_sec` defaulting to
   `DEFAULT_TIMEOUT_SEC` when neither cfg nor descriptor provides one, and the
   stage profile.
7. Re-read `stage.state_file` and map markers: `WAITING` → `round_waiting`,
   `COMPLETE` → `complete`, `ERROR` → `error`, otherwise `marker.name.to_s`.

The coding pipeline's `brainstorm` and `plan` names still use their bespoke
tmux-capable runners even though their descriptor entries are `kind: :agent`;
name-first resolver precedence preserves the current coding runtime.

## Tests

- `test/unit/stages/agent_test.rb` covers prior-artifact selection, nonce
  wrapping, nil-skill fallback, formatted skill invocation, spawn arguments,
  budget/timeout overrides, and marker-to-action mapping.

## Backlinks

- [[modules/workflows]]
- [[stages/index]]
- [[modules/markers]]
