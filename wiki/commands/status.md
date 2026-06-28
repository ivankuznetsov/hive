---
title: hive status
type: command
source: lib/hive/commands/status.rb
created: 2026-04-25
updated: 2026-06-28
tags: [command, status, observability, json, diagnostics, legacy-dirs, task-id, archive, dependencies, pr]
---

**TLDR**: `hive status` walks every registered project's `.hive-state/stages/<N>-<name>/<slug>/` directory across `Hive::Workflows.all_stage_dirs`, reads each task's marker and `meta.yml`, resolves same-project task dependencies, and prints human task identities grouped by the next useful action. Status scans tolerate normal stage-move races: vanished task folders are skipped, and duplicate-slug rows are collapsed only when one duplicate folder has already disappeared. Normal text status hides `9-done` tasks whose row `mtime` is older than 3 days and prints a count summary; `hive status --json` still emits every row for daemon/bot consumers. `hive archive` with no target delegates to status archive mode for the age-unfiltered archive listing. Pass `--diagnose <task>` to inspect one red row, and add `--write` only when you want the configured development agent to write `diagnostics/red-status.md`.

## Output shape

```
<project_name>
  Ready to brainstorm
    ⏸ #42  —     Add inbox filter      waiting                  hive brainstorm add-inbox-filter-260424-7a3b 2h ago
  Ready to develop
    ✓ #43  #561  Refactor auth flow    complete                 hive develop refactor-auth-260423-1c2d 1d ago
  Agent running
    🤖 —    —     add-cache-260424-9a8b agent_working pid=1234   - 5m ago
```

`hive status` prints one block per project. Action buckets without active tasks are skipped. Within a bucket, rows are sorted by state-file mtime (newest first). The human identity column renders `#id PR display_name` when available, falls back to `#id PR slug`, and uses `— PR slug` when pre-migration/counter-failed tasks have no id. The PR slot is fixed-width: rows with no parseable PR URL render `—`, while pull-request URLs render `#<number>` and become OSC 8 hyperlinks only when stdout is a TTY. Commands and internal paths continue to use the slug. Raw slug, id, display name, stage, folder, and timestamps remain available in `--json`. JSON rows include both `mtime` (the state-file mtime used for age, sort order, and daemon edit baselines) and `folder_mtime` (the task directory mtime, emitted from `collect_rows` even when the state file exists). Both JSON timestamps are ISO8601 with six fractional digits so daemon consumers preserve the subsecond `File.mtime` ordering they compare against dispatch baselines. `folder_mtime` is useful for consumers that need folder-level aging, especially archived task rows where the terminal marker file may not reflect later directory-level activity.

Rows also include `workflow`, the descriptor id that resolved the task (`"coding"` for legacy/default rows, or the `meta.yml workflow:`/project default id for registered non-coding tasks). Row-based consumers such as the daemon and Telegram bot use it to keep coding-only plan/brainstorm/review/finalize behavior from firing for generic tasks.

Rows also include `pr_url`: once a coding task reaches `5-open-pr` or later, status reads `<task>/pr.md` frontmatter through `Hive::Gh.pr_frontmatter` and emits a stripped non-empty `pr_url`; before a PR exists, or when `pr.md` is missing, blank, or malformed, the field is `null`. This is a sibling task-payload field, not copied out of marker attrs, so consumers do not need to scrape `<!-- COMPLETE pr_url=... -->`.

JSON rows also include `next_action`; it is usually `null`, but `EXECUTE_WAITING reason=...` rows carry the same structured recovery target that `hive run --json` emits. Every JSON row also includes `diagnostic`; it is `null` for ordinary rows and a bounded red-row payload for `recover_execute`, `recover_review`, and `error` rows. JSON rows carry `unanswered_questions` (issue #270): the count of still-unanswered `### Q{n}.` slots for a `2-brainstorm` `needs_input` row (computed via the shared `Hive::BrainstormParser`), and `0` for every other row. It lets an agent/operator tell a brainstorm the [[modules/daemon]] answers-pending gate is intentionally holding (count > 0) from one genuinely waiting for a first answer or broken. Dependency fields are also present on every task row: `depends_on`, `blocked_by`, `dependency_stage`, and `blocked`; text and TUI rows append `⏸ blocked by <slug> (<stage>)` or `(unresolved)` when `blocked` is true. The daemon consumes that `blocked` boolean directly.

## Archived tasks

`Hive::ArchiveFilter` is the shared policy for day-to-day archive hiding. A row is hideable when `stage == Hive::Stages::DIRS.last` (`9-done`), the row timestamp is present, and `(now - mtime) > 3 days`. Marker state is not part of the policy: complete, unresolved, and markerless done rows all use the same age rule. The policy uses the task row's `mtime` (state-file mtime, the same timestamp rendered as row age) rather than `folder_mtime`, because sidecar updates such as `meta.yml` display-name backfills can touch the directory without making the archived task newly relevant. Older consumers that only have `folder_mtime` still get it as a fallback. If neither timestamp is available, the filter fails open and keeps the row visible rather than guessing. `hive archive` remains the full view.

The filter applies only to human daily surfaces: default `hive status` text and the TUI grid. Default `hive status --json` stays unfiltered so bots, daemons, and agents continue to see every task row. Text status prints `… and N archived >3d ago (hive archive to view)` when rows were hidden.

`hive archive` with no target reuses Status in archive mode (`Hive::Commands::Status.new(archive: true)`): it lists only `9-done` tasks, with no age cutoff and no hidden-count summary. Empty archive projects print `no archived tasks`. Text rows are sorted newest-first by `mtime` and use the same id/PR/display-name identity column as daily status. `hive archive --json` emits a focused `hive-status` payload whose project task arrays contain only `9-done` rows. `hive archive <slug>` still runs the workflow verb that advances a completed finalize task into done.

## Legacy stage directories (`legacy_stage_dirs`)

Every Project entry in `hive status --json` carries a `legacy_stage_dirs` array — `[]` for healthy projects, otherwise a list of `{ "stage_dir": "<name>", "task_count": <N> }` entries (sorted alphabetically by `stage_dir`). The field is populated by `Status#detect_legacy_stage_dirs`, which scans `<hive_state>/stages/` for directories that are **not** in `Hive::Workflows.all_stage_dirs`, are not status-private siblings such as `archived-manual/`, and contain at least one slug-shaped task subfolder (per `Hive::Stages.task_slug?`, the same predicate `hive migrate` uses to decide which entries it is allowed to mv — so the count reflects what `hive migrate` would actually move). Stray non-slug siblings (`logs/`, `.gitkeep`, `.DS_Store`) are ignored.

When the field is non-empty, the text output prints a warning under the project header:

```
<project_name>
  ⚠ 2 tasks hidden in legacy stage dirs: 5-review (1), 6-pr (1)
    run `hive migrate` to move them into the current layout
```

The warning is singular for one hidden task (`1 task hidden`) and plural otherwise. The TUI projects pane mirrors the warning by prefixing the affected project's name with `⚠` and the short hint `legacy dirs — run hive migrate`. The Telegram bot also sends a proactive project-level notification on the clean-to-legacy transition, deduped by the bot alert store while the project remains legacy-dirty, even if the hidden task count changes. Bot messages include a project-path-scoped `hive migrate <project_path>` command because the bot is global. Running `hive migrate` moves the slugs into the canonical stage directory listed in `Hive::Commands::Migrate::STAGE_RENAMES`, and after the next status poll the warning disappears.

The `legacy_stage_dirs` field was an additive, non-breaking extension of `urn:hive:schema:status:v2`. Task `id` / `display_name` fields bumped the status schema to v3 and the diagnose schema to v2. Dependency fields bumped `hive-status` to v4; `blocked` is required while `depends_on`, `blocked_by`, and `dependency_stage` are nullable. `folder_mtime` and `pr_url` are part of the current `hive-status` task payload.

## Icon legend (`Status::ICON`, `lib/hive/commands/status.rb:11`)

| Icon | Marker name |
|------|-------------|
| `·` | `:none` (no marker yet, e.g. fresh `1-inbox` capture before WAITING was added) |
| `⏸` | `:waiting`, `:execute_waiting`, `:review_waiting` |
| `✓` | `:complete`, `:execute_complete`, `:review_complete` |
| `🤖` | `:agent_working` with a live PID, `:review_working`, or a live per-task `.lock` holder before a Claude PID is recorded |
| `⚠` | `:execute_stale`, `:review_ci_stale`, `:review_stale`, `:review_error`, `:error`, or `:agent_working` with a dead PID |

`decorate` special-cases `:agent_working`: reads `claude_pid` from the per-task `.lock` (or fallback marker `pid`) and runs `Process.kill(0, pid)` to decide between 🤖 and ⚠ "stale lock". If the task lock is live but the Claude PID is not attached yet, status renders `🤖 run_lock pid=<pid>` instead of a stale warning. This is internal display state, not an added JSON field.

## Rendering rules

- Empty registry → `"(no projects registered; run `hive init <path>`)"`.
- Project path missing → `"<name>: missing project path <path>"`.
- `.hive-state` missing → `"<name>: not initialised (no .hive-state)"`.
- Action bucket with no tasks → header omitted entirely.
- Old `9-done` rows → hidden from text output by age alone, regardless of marker state, with the per-project summary line above.
- Daily and archive-mode task identity is left-padded to 49 chars; it includes id, fixed-width PR token, and display name/slug. State label is left-padded to 24 chars, followed by the suggested command and humanised age. Marker attr values in the state label collapse internal whitespace so multi-line stderr details do not break the table.

`humanise_age` thresholds: `<60s → Ns ago`, `<3600s → Nm ago`, `<86400s → Nh ago`, else `Nd ago`.

## How tasks are discovered

For each stage in `Hive::Workflows.all_stage_dirs` (the union of every live registered descriptor; coding remains the default source of truth via `Hive::Stages::DIRS`), `collect_rows` globs `<hive_state>/stages/<stage>/*` directories through the `stage_task_entries(stage_dir)` seam. Each entry is parsed via `Hive::Task.new(entry)`; non-conforming directories (no slug match, or a folder whose `workflow` selector does not contain that stage) are silently skipped via `rescue InvalidTaskPath`. Marker is read with `Hive::Markers.current(task.state_file)`. `folder_mtime` is always `File.mtime(entry)`; `mtime` is the state-file mtime when the state file exists, otherwise the same directory mtime fallback.

Stage moves are treated as a normal filesystem race. If an entry disappears between the stage glob and any in-folder row read, `collect_rows` rescues `Errno::ENOENT`, re-checks the folder path, and skips it only when the folder is gone. The rescue is deliberately folder-level: an `ENOENT` while the task folder still exists is re-raised as a real status command failure, because in-place state-file writers may truncate content but should not make the state file transiently absent inside a surviving folder. A forward stage move can resurface under the later stage in the same scan; a backward move to an already-scanned stage can disappear for one poll and then reappear on the next refresh. After all stages are scanned, `drop_transient_stage_moves` looks only at duplicate-slug groups and removes every duplicate row whose folder no longer exists. If two live folders still share a slug, both rows remain and `annotate_actions` still passes `stage_collision: true` into `Hive::TaskAction`. This keeps `hive status --json` and TUI snapshots from briefly showing an old-stage and new-stage copy during a normal `mv`, without hiding persistent duplicate state.

Rows are then classified by `Hive::TaskAction`, which emits an action key, label, suggested command, and optional row-local `next_action` such as `kind=edit target=<worktree>` for dirty execute worktrees or `kind=run` for `missing_research_output`. `collect_rows` also reads each task `.lock`, verifies the holder PID and recorded process start time through `Hive::Lock`, and passes `live_task_lock: true` to `TaskAction` while `hive run` is active even if the stage has not written an `AGENT_WORKING` or `REVIEW_WORKING` marker yet. If one project has the same slug in multiple stages, workflow commands include `--from <stage>` and generic findings commands include `--stage <stage>`.

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

Without `--write`, `--diagnose` resolves the target via `Hive::TaskResolver` and prints the same local diagnostic payload used by `hive status --json`. This is read-only. If the task's current marker no longer classifies as a red recovery action but the task folder still has evidence on disk, `Hive::DiagnosticEvidence` fills the nil-diagnostic gap from `diagnostics/red-status.md`, the newest meaningful `logs/*.log` line, or the current marker file. That fallback emits a one-line summary plus a source path instead of a bare "no diagnostic" result.

With `--write`, `Hive::DiagnosisAgent` uses the configured development profile (`execute.agent` via `Hive::Stages::Base.stage_profile`) to produce a concise markdown diagnosis, then atomically writes `<task>/diagnostics/red-status.md`. Defaults are `timeout_sec.diagnose || 600` and `budget_usd.diagnose || 5`. The agent gets the task folder as an add-dir and runs from the task worktree when one exists, otherwise the project root. The worktree pointer is validated against the configured worktree root before it is used as cwd. Custom execute profiles are rejected for diagnose unless their `generated_by` value has first been added to `Hive::Schemas::DIAGNOSTIC_GENERATORS` and the published schemas. The command does not claim the task lock and does not write workflow markers.

JSON output uses schema `hive-status-diagnose`, version `2`, and returns `slug`, `id`, `display_name`, `task_folder`, `marker_summary`, `diagnostic`, and `path` (set only when `--write` wrote an artifact). `marker_summary` is the current marker name plus display attrs and is present even when `diagnostic` is null.

## Read-only

Normal `status` and `status --diagnose` without `--write` do not mutate filesystem state, do not commit, do not spawn agents, and do not touch locks. `status --diagnose --write` is the explicit mutation path: it spawns the configured development agent and writes only `diagnostics/red-status.md`.

## Tests

- `test/integration/status_test.rb` — empty registry, action grouping, suggested commands, stale-lock decoration.
- `test/unit/commands/status_test.rb` — status row collection, vanished-folder and transient duplicate stage-move races, non-finalize forward moves, state-file `ENOENT` re-raise when the folder survives, multi-row duplicate pruning, genuine collision preservation, corrupted finalize rows, legacy dir warnings, live task-lock action override, `folder_mtime` JSON emission, `pr_url` extraction from `pr.md` frontmatter, text/archive PR-column rendering, old-archive hiding, and archive-mode listing.
- `test/unit/commands/status_diagnose_test.rb` — local diagnose JSON and agent-written artifact refresh.
- `test/unit/task_action_test.rb` — diagnostic extraction, redaction, artifact selection, marker fallback, non-red nil.

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]]
- [[modules/markers]] · [[modules/task]] · [[modules/task_action]] · [[modules/task_dependencies]] · [[modules/config]]
