---
title: Hive::Stages
type: module
source: lib/hive/stages.rb
created: 2026-04-25
updated: 2026-04-25
tags: [module, stages, constants]
---

**TLDR**: Single source of truth for the six-stage list. Constants `DIRS`, `NAMES`, `SHORT_TO_FULL`; helpers `next_dir(idx)`, `resolve(name)`, `parse(dir)`. Every consumer (`GitOps`, `Status`, `Run#next_stage_dir`, `Approve`) delegates here so adding a 7th stage is a one-file change.

## Constants

- `DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done]` — the canonical stage directory names (index + bare name).
- `NAMES = %w[inbox brainstorm plan execute pr done]` — bare stage names without the index prefix; same as `Hive::Task::STAGE_NAMES`.
- `SHORT_TO_FULL = { "inbox" => "1-inbox", … }` — frozen hash for short→full resolution.

## Helpers (`module_function`)

- `next_dir(idx)` — directory for the stage *after* the given 1-based index. Returns nil at or past the final stage. Raises `ArgumentError` for non-integer or `idx < 1` so off-by-ones surface at the call site rather than silently returning nil.
- `resolve(name)` — accepts either `"3-plan"` or `"plan"` and returns the canonical `DIRS` entry, or nil if neither shape matches.
- `parse(dir)` — `"3-plan"` → `[3, "plan"]`. Returns nil for inputs that aren't known stages (`"99-foo"` → nil rather than `[99, "foo"]`) so a hand-constructed stage string can't slip past validation.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/git_ops.rb` | `Hive::Stages::DIRS.each` in `hive_state_init` to mkdir each stage directory. |
| `lib/hive/commands/status.rb` | `Hive::Stages::DIRS.each` in `render_project` and `collect_rows` to iterate stages in order. |
| `lib/hive/commands/run.rb` | `Hive::Stages.next_dir(task.stage_index)` in `next_stage_dir`. |
| `lib/hive/commands/approve.rb` | `DIRS` for slug-cross-project search; `next_dir`, `resolve`, `parse` for `--to` / `--from` validation, destination resolution, no-op detection, and direction calculation. |
| `lib/hive/cli.rb` | `(DIRS + NAMES)` builds the Thor `enum:` constraint on `--to` / `--from`. |

## Why a module rather than a class?

The values are pure data + pure functions. No state, no construction. `module_function` makes the helpers callable as `Hive::Stages.next_dir(2)` without instantiation.

## Backlinks

- [[state-model]] · [[modules/git_ops]] · [[modules/task]]
- [[commands/status]] · [[commands/run]] · [[commands/approve]]
- [[cli]]
