---
title: Generic Agent Stage Runner
type: stage
source: lib/hive/stages/agent.rb, templates/agent_prompt.md.erb
created: 2026-06-19
updated: 2026-07-13
tags: [stage, agent, workflow]
---

**TLDR**: `Hive::Stages::Agent` is the shared headless runner for descriptor
stages whose `kind` is `:agent` and whose name does not already have a bespoke
coding runner. `Hive::Stages::Resolver` reaches it as the fallback after the
coding-name runner table. The runner resolves the active stage per-task via
`task.workflow.stage_named(task.stage_name)` (the core U6 generic behavior — NOT
the coding-pinned `Hive::Workflows::Registry.default`), renders
`templates/agent_prompt.md.erb`, resolves descriptor-level `agent`/`model`/`effort`
overrides, spawns one folder-isolated agent, and maps the resulting state-file
marker to the same commit actions as [[stages/brainstorm]]. A workflow may end
on this runner; terminal agent stages require `COMPLETE` plus a non-empty
deliverable before status reports them archived.

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
6. Resolve the profile using descriptor `stage.agent`, then project
   `cfg[stage]["agent"]`, then `claude`. Descriptor `stage.model` /
   `stage.effort` override project Claude defaults for this spawn.
7. Spawn via `Hive::Stages::Base.spawn_agent` with `add_dirs:` from the resolved
   permission scope (`scope.fetch(:add_dirs)` — `[task.folder]` by default, but a
   `scoped` permissions block with `dirs:` appends extra directories beyond the
   task folder), `cwd: task.folder`, the descriptor's `status_mode` (falling back
   to `:state_file_marker` only when unset), and the stage profile. Descriptor
   `budget_usd` / `timeout_sec` values provide resource defaults that project
   stage config can override only when a non-null key was explicitly authored
   in the project YAML; values injected by `Config.merge_defaults` do not shadow a
   descriptor default. Timeout falls back to `DEFAULT_TIMEOUT_SEC` when neither
   source provides one. A budget is per spawn and only enforced when the
   selected profile has a native `budget_flag`; otherwise `spawn_agent` records
   the dropped cap in `config-warnings.log` while still enforcing timeout.
   Scoped file rules such as `Edit(../../../../docs/**)` are normalized from the
   task-relative descriptor form to Claude's absolute `Edit(//.../docs/**)`
   form and run under `dontAsk`, so matching writes proceed while a write
   unmatched by any loaded permission rule is denied without hanging the
   headless stage. Loaded Claude setting sources can add broader trusted
   operator allow rules; the descriptor does not erase them.
8. Re-read `stage.state_file` and map markers: `WAITING` → `round_waiting`,
   `COMPLETE` → `complete`, `ERROR` → `error`, `NONE` → `nil` (an explicit arm —
   a markerless run has nothing to commit, so `commit_after` skips the commit),
   otherwise `marker.name.to_s`. A provider-limit error is the exception to the
   plain `ERROR` action: if `Hive::Agent` already wrote
   `ERROR reason=limits_reached`, the runner preserves that marker; if a
   non-state-file spawn only returned quota text in its error envelope, the
   runner writes the equivalent marker with the selected profile as `provider`.
   Both paths return `commit=limits_reached` and retain a `retry_after` stamp so
   the daemon cooldown healer can requeue the generic stage. Non-limit error
   envelopes still become `ERROR reason=agent_preflight_failed`.

The coding pipeline's `brainstorm` and `plan` names still use their bespoke
tmux-capable runners even though their descriptor entries are `kind: :agent`;
name-first resolver precedence preserves the current coding runtime.

## Tests

- `test/unit/stages/agent_test.rb` covers prior-artifact selection, nonce
  wrapping, nil-skill fallback, formatted skill invocation, spawn arguments,
  descriptor-versus-loaded-config resource precedence, explicit budget/timeout
  overrides, marker-to-action mapping, provider-limit envelope classification,
  preservation of agent-written quota markers, and the distinct non-limit
  preflight fallback.

## Backlinks

- [[modules/workflows]]
- [[stages/index]]
- [[modules/markers]]
