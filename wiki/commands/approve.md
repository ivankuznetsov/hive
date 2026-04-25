---
title: hive approve
type: command
source: lib/hive/commands/approve.rb
created: 2026-04-25
updated: 2026-04-25
tags: [command, approval, json]
---

**TLDR**: `hive approve TARGET [--to STAGE] [--project NAME] [--force] [--json]` moves a task folder between stages and records a commit on `hive/state`. The agent-callable replacement for shell `mv <task> <next-stage>/` — same effect, plus marker validation, ambiguity resolution, and a structured exit-code / JSON contract.

## Usage

```
hive approve <slug>                        # auto: current stage → next stage
hive approve <slug> --to <stage>           # explicit destination (forward or backward)
hive approve <slug> --project <name>       # disambiguate when slug exists in 2+ projects
hive approve <slug> --force                # bypass terminal-marker check on forward move
hive approve <task-folder> [...]           # take a folder path instead of a slug
hive approve <slug> --json                 # machine-readable result
```

## Steps performed (`Commands::Approve#call`)

1. `resolve_target`: if `TARGET` is a directory, use it; otherwise treat as a slug and scan registered projects' `.hive-state/stages/*/{<slug>/}` for an unambiguous match.
2. `Hive::Task.new(folder)` parses the path into `{project, stage, slug}`.
3. `resolve_destination`: `--to` (long or short stage name), or auto = current stage_index + 1. Errors out at `6-done`.
4. `validate_move!`: forward auto-advance requires `:complete` or `:execute_complete` marker. `--to` (any direction) and `--force` both bypass.
5. `move_task!`: `FileUtils.mv` from source to destination folder; aborts on destination collision.
6. `record_hive_commit`: `git add -A` on both source and destination *parent stage directories* (so deletion + addition are both staged), then commit with `hive: <from>/<slug> approve <from> -> <to>`.
7. Report: human prose by default; one-line `hive-approve` JSON document with `--json`.

## JSON contract (`schema = "hive-approve"`, version 1)

```json
{
  "schema": "hive-approve",
  "schema_version": 1,
  "slug": "fix-bug-260424-aaaa",
  "from_stage": "2-brainstorm",
  "to_stage": "3-plan",
  "from_folder": "/home/you/Dev/proj/.hive-state/stages/2-brainstorm/fix-bug-260424-aaaa",
  "to_folder":   "/home/you/Dev/proj/.hive-state/stages/3-plan/fix-bug-260424-aaaa",
  "commit_action": "approve 2-brainstorm -> 3-plan"
}
```

Pinned by `Hive::Schemas::SCHEMA_VERSIONS["hive-approve"]` and `test/integration/run_approve_test.rb#test_json_output_emits_stable_schema`.

## Slug resolution rules

- **Slug not found**: `Hive::InvalidTaskPath` → exit 64 (USAGE).
- **Slug appears in multiple stages of the same project**: prefer the lowest stage index. This is almost always the active task; if a stale leftover exists in a later stage, the user can clean it up afterwards.
- **Slug appears in multiple projects**: ambiguous → exit 64 with a hint to pass `--project <name>`.
- **`--project NAME`**: scope the slug lookup to a single registered project.

## Marker policy

| Direction | Marker required | Override |
|-----------|-----------------|----------|
| Forward auto (no `--to`) | `:complete` or `:execute_complete` | `--force` |
| Explicit `--to STAGE` (any direction) | none | n/a |

This keeps the happy path safe (you can't auto-advance a task that hasn't terminated its stage) while still allowing recovery flows like `hive approve <slug> --to 3-plan` to move a 4-execute task back for re-planning.

## Exit codes

| Condition | Exit | Class |
|-----------|------|-------|
| Success | 0 | — |
| Slug not found / ambiguous / unknown `--to` stage | 64 (`USAGE`) | `Hive::InvalidTaskPath` |
| Forward move without terminal marker (no `--force`) | 4 (`WRONG_STAGE`) | `Hive::WrongStage` |
| Destination already exists, advancing past `6-done`, etc. | 1 (`GENERIC`) | `Hive::Error` |

## Why not just use `mv`?

`mv` works fine for humans. Agent callers want:
- a stable exit code on each failure mode (no parsing stderr)
- a single source of truth for stage names (`--to plan` ≡ `--to 3-plan`)
- a marker check that prevents "approve a WAITING task" mistakes
- an audit-trail commit on `hive/state` recording the approval (with `mv`, only the next `hive run` would commit, and the move itself is invisible until then)
- a JSON output mode for chained automation

`hive approve` adds all of that without removing the manual `mv` path — the two coexist.

## Backlinks

- [[cli]]
- [[commands/run]]
- [[commands/status]]
- [[stages/index]]
