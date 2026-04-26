---
title: hive status
type: command
source: lib/hive/commands/status.rb
created: 2026-04-25
updated: 2026-04-25
tags: [command, status, observability, json]
---

**TLDR**: `hive status` walks every registered project's `.hive-state/stages/<N>-<name>/<slug>/` directory, reads each task's marker, and prints slugs grouped by the next useful action. Read-only; takes no args. Pass `--json` for a single machine-readable document on stdout (schema `hive-status`, version per `Hive::SCHEMA_VERSIONS`).

## Output shape

```
<project_name>
  Ready to brainstorm
    ⏸ add-inbox-filter-260424-7a3b   waiting                  hive brainstorm add-inbox-filter-260424-7a3b 2h ago
  Ready to develop
    ✓ refactor-auth-260423-1c2d      complete                 hive develop refactor-auth-260423-1c2d 1d ago
  Needs your input
    🤖 add-cache-260424-9a8b          agent_working pid=1234   hive develop add-cache-260424-9a8b 5m ago
```

`hive status` prints one block per project. Action buckets without active tasks are skipped. Within a bucket, rows are sorted by state-file mtime (newest first). Raw stage and folder remain available in `--json`.

## Icon legend (`Status::ICON`, `lib/hive/commands/status.rb:11`)

| Icon | Marker name |
|------|-------------|
| `·` | `:none` (no marker yet, e.g. fresh `1-inbox` capture before WAITING was added) |
| `⏸` | `:waiting`, `:execute_waiting` |
| `✓` | `:complete`, `:execute_complete` |
| `🤖` | `:agent_working` with a live PID |
| `⚠` | `:execute_stale`, `:error`, or `:agent_working` with a dead PID |

`decorate` (`lib/hive/commands/status.rb:95`) special-cases `:agent_working`: reads `claude_pid` (or fallback `pid`) from the marker attrs and runs `Process.kill(0, pid)` to decide between 🤖 and ⚠ "stale lock".

## Rendering rules

- Empty registry → `"(no projects registered; run `hive init <path>`)"`.
- Project path missing → `"<name>: missing project path <path>"`.
- `.hive-state` missing → `"<name>: not initialised (no .hive-state)"`.
- Action bucket with no tasks → header omitted entirely.
- Slug is left-padded to 36 chars; state label to 24 chars; then the suggested command and humanised age.

`humanise_age` thresholds: `<60s → Ns ago`, `<3600s → Nm ago`, `<86400s → Nh ago`, else `Nd ago`.

## How tasks are discovered

For each stage in `Hive::Stages::DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done]` (single source of truth — see [[modules/stages]]), `collect_rows` globs `<hive_state>/stages/<stage>/*` directories. Each is parsed via `Hive::Task.new(entry)`; non-conforming directories (no slug match) are silently skipped via `rescue InvalidTaskPath`. Marker is read with `Hive::Markers.current(task.state_file)`; mtime falls back to the directory mtime if the state file doesn't exist yet.

Rows are then classified by `Hive::TaskAction`, which emits an action key, label, and suggested command such as `hive brainstorm <slug>`, `hive develop <slug>`, `hive findings <slug>`, or `hive pr <slug>`. If one project has the same slug in multiple stages, workflow commands include `--from <stage>` and generic findings commands include `--stage <stage>`.

## Read-only

`status` does not mutate filesystem state, does not commit, does not spawn agents, and does not touch locks. Safe to run while other `hive run` commands are in flight.

## Tests

- `test/integration/status_test.rb` — empty registry, action grouping, suggested commands, stale-lock decoration.

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]]
- [[modules/markers]] · [[modules/task]] · [[modules/config]]
