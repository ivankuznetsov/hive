---
title: Generic Agent Stage Runner
type: stage
source: lib/hive/stages/agent.rb, templates/agent_prompt.md.erb
created: 2026-06-19
updated: 2026-07-09
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
8. Re-read `stage.state_file` and map markers: `WAITING` → `round_waiting`,
   `COMPLETE` → `complete`, `ERROR` → `error`, `NONE` → `nil` (an explicit arm —
   a markerless run has nothing to commit, so `commit_after` skips the commit),
   otherwise `marker.name.to_s`.

An error envelope does not by itself prove that the spawn wrote no marker.
`Hive::Agent` writes specific state-file errors for provider limits, timeouts,
and nonzero exits, while version/auth preflight failures return the same error
envelope without changing the file. The runner snapshots the terminal marker
before spawning and synthesizes `ERROR reason=agent_preflight_failed` only when
the marker remains unchanged. Fresh agent-written errors therefore retain
their reason and recovery metadata, including the `limits_reached`
`retry_after` consumed by the daemon healer.

The coding pipeline's `brainstorm` and `plan` names still use their bespoke
tmux-capable runners even though their descriptor entries are `kind: :agent`;
name-first resolver precedence preserves the current coding runtime.

## Tests

- `test/unit/stages/agent_test.rb` covers prior-artifact selection, nonce
  wrapping, nil-skill fallback, formatted skill invocation, spawn arguments,
  descriptor-versus-loaded-config resource precedence, explicit budget/timeout
  overrides, marker-to-action mapping, preflight marker synthesis, and
  preservation of fresh retryable agent error markers.

## Backlinks

- [[modules/workflows]]
- [[stages/index]]
- [[modules/markers]]
