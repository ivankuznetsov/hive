---
title: hive status
type: command
source: lib/hive/commands/status.rb
created: 2026-04-25
updated: 2026-05-19
tags: [command, status, observability, json, diagnostics]
---

**TLDR**: `hive status` walks every registered project's `.hive-state/stages/<N>-<name>/<slug>/` directory, reads each task's marker, and prints slugs grouped by the next useful action. Normal status is read-only and takes no args. Pass `--json` for a single machine-readable document on stdout (schema `hive-status`, version per `Hive::SCHEMA_VERSIONS`). Pass `--diagnose <task>` to inspect one red row, and add `--write` only when you want the configured development agent to write `diagnostics/red-status.md`.

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

`hive status` prints one block per project. Action buckets without active tasks are skipped. Within a bucket, rows are sorted by state-file mtime (newest first). Raw stage and folder remain available in `--json`. JSON rows also include `next_action`; it is usually `null`, but `EXECUTE_WAITING reason=...` rows carry the same structured recovery target that `hive run --json` emits. Every JSON row also includes `diagnostic`; it is `null` for ordinary rows and a bounded red-row payload for `recover_execute`, `recover_review`, and `error` rows.

## Icon legend (`Status::ICON`, `lib/hive/commands/status.rb:11`)

| Icon | Marker name |
|------|-------------|
| `·` | `:none` (no marker yet, e.g. fresh `1-inbox` capture before WAITING was added) |
| `⏸` | `:waiting`, `:execute_waiting`, `:review_waiting` |
| `✓` | `:complete`, `:execute_complete`, `:review_complete` |
| `🤖` | `:agent_working` with a live PID, `:review_working` |
| `⚠` | `:execute_stale`, `:review_ci_stale`, `:review_stale`, `:review_error`, `:error`, or `:agent_working` with a dead PID |

`decorate` (`lib/hive/commands/status.rb:95`) special-cases `:agent_working`: reads `claude_pid` (or fallback `pid`) from the marker attrs and runs `Process.kill(0, pid)` to decide between 🤖 and ⚠ "stale lock".

## Rendering rules

- Empty registry → `"(no projects registered; run `hive init <path>`)"`.
- Project path missing → `"<name>: missing project path <path>"`.
- `.hive-state` missing → `"<name>: not initialised (no .hive-state)"`.
- Action bucket with no tasks → header omitted entirely.
- Slug is left-padded to 36 chars; state label to 24 chars; then the suggested command and humanised age.

`humanise_age` thresholds: `<60s → Ns ago`, `<3600s → Nm ago`, `<86400s → Nh ago`, else `Nd ago`.

## How tasks are discovered

For each stage in `Hive::Stages::DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 6-review 7-finalize 8-done]` (single source of truth — see [[modules/stages]]), `collect_rows` globs `<hive_state>/stages/<stage>/*` directories. Each is parsed via `Hive::Task.new(entry)`; non-conforming directories (no slug match) are silently skipped via `rescue InvalidTaskPath`. Marker is read with `Hive::Markers.current(task.state_file)`; mtime falls back to the directory mtime if the state file doesn't exist yet.

Rows are then classified by `Hive::TaskAction`, which emits an action key, label, suggested command, and optional row-local `next_action` such as `kind=edit target=<worktree>` for dirty execute worktrees or `kind=run` for `missing_research_output`. If one project has the same slug in multiple stages, workflow commands include `--from <stage>` and generic findings commands include `--stage <stage>`.

## Red-row diagnostics

`TaskAction#diagnostic` is the local source for red status rows. It returns:

- `summary` — marker name plus marker attrs, truncated and secret-redacted.
- `detail` — the tail of the best matching artifact, or marker fallback text when no artifact exists.
- `source` / `source_path` — whether the detail came from an artifact or marker fallback.
- `artifact_paths` — every relevant artifact discovered for this marker.
- `generated_by` — `local` for bounded extraction, or one of the schema-listed diagnose generators (`claude`, `codex`, `pi`) that wrote a fresh diagnosis artifact.
- `updated_at` — mtime of the source artifact or marker state file.

Artifact discovery is marker-specific. Review errors prefer `diagnostics/red-status.md` when it matches the current marker, then pass-specific files such as `reviews/errors-NN.md`, `reviews/fix-guardrail-NN.md`, `reviews/escalations-NN.md`, marker `files=...` entries, phase logs, and latest logs. `review_ci_stale` includes `reviews/ci-blocked.md` and CI-fix logs. `review_stale` includes the pass escalations/reviewer files. `execute_stale` includes review files and logs. Generic `ERROR` includes recent logs and the task state file.

Fresh agent-written diagnostics live at `<task>/diagnostics/red-status.md`. Normal status trusts that file only when:

- frontmatter parses;
- `generated_by` is in `Hive::Schemas::DIAGNOSTIC_GENERATORS` (`local`, `claude`, `codex`, `pi`);
- `marker_signature` matches the current marker name plus sorted attrs.

That signature check prevents a stale diagnosis from explaining a new failure after the marker changes.

## `--diagnose`

```
hive status --diagnose <slug-or-folder> [--project <name>] [--stage <stage>] [--json]
hive status --diagnose <slug-or-folder> [--project <name>] [--stage <stage>] --write [--json]
```

Without `--write`, `--diagnose` resolves the target via `Hive::TaskResolver` and prints the same local diagnostic payload used by `hive status --json`. This is read-only.

With `--write`, `Hive::DiagnosisAgent` uses the configured development profile (`execute.agent` via `Hive::Stages::Base.stage_profile`) to produce a concise markdown diagnosis, then atomically writes `<task>/diagnostics/red-status.md`. Defaults are `timeout_sec.diagnose || 600` and `budget_usd.diagnose || 5`. The agent gets the task folder as an add-dir and runs from the task worktree when one exists, otherwise the project root. The worktree pointer is validated against the configured worktree root before it is used as cwd. Custom execute profiles are rejected for diagnose unless their `generated_by` value has first been added to `Hive::Schemas::DIAGNOSTIC_GENERATORS` and the published schemas. The command does not claim the task lock and does not write workflow markers.

JSON output uses schema `hive-status-diagnose`, version `1`, and returns `slug`, `task_folder`, `diagnostic`, and `path` (set only when `--write` wrote an artifact).

## Read-only

Normal `status` and `status --diagnose` without `--write` do not mutate filesystem state, do not commit, do not spawn agents, and do not touch locks. `status --diagnose --write` is the explicit mutation path: it spawns the configured development agent and writes only `diagnostics/red-status.md`.

## Tests

- `test/integration/status_test.rb` — empty registry, action grouping, suggested commands, stale-lock decoration.
- `test/unit/commands/status_diagnose_test.rb` — local diagnose JSON and agent-written artifact refresh.
- `test/unit/task_action_test.rb` — diagnostic extraction, redaction, artifact selection, marker fallback, non-red nil.

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]]
- [[modules/markers]] · [[modules/task]] · [[modules/task_action]] · [[modules/config]]
