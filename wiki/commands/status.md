---
title: hive status
type: command
source: lib/hive/commands/status.rb, lib/hive/task_closure.rb, lib/hive/operational_status.rb, lib/hive/operational_action.rb, lib/hive/daemon/operational_snapshot.rb, lib/hive/diagnostic_evidence.rb
created: 2026-04-25
updated: 2026-07-25
tags: [command, status, operational, agents, observability, json, diagnostics, archive, closure, dependencies, scheduler]
---

**TLDR**: `hive status` now defaults to a compact operational snapshot for
humans: closed state bands, counts, exact blocker ownership/reasons, and at
most five representative rows per band. `hive status --operational --json`
emits the additive agent contract `hive-operational-status.v2`. The established
complete task graph remains unchanged as `hive status --json`
(`hive-status.v6`), and `hive status --full` keeps the former detailed human
table.

## Mode contract

| Invocation | Contract |
|---|---|
| `hive status` | Concise human operational snapshot. |
| `hive status --operational` | Explicit alias for the same concise human view. |
| `hive status --operational --json` | `hive-operational-status.v2` agent document. The recovery rollout migrated every in-repository consumer to v2 and removed v1. |
| `hive status --json` | Unchanged complete `hive-status.v6` compatibility graph for daemon, bot, TUI, and pinned consumers. |
| `hive status --full` | Former grouped detailed human table. |
| `hive status --diagnose ...` | Existing task diagnostic surface; incompatible with `--operational`/`--full`. |

`--full` cannot be combined with `--json` or `--operational`. Archive mode and
diagnosis retain their established contracts.

The operational document projects every non-archived task into exactly one of
seven states: `running`, `needs_repair`, `waiting_on_you`,
`waiting_on_provider_or_scheduler`, `completion_ready`, `idle`, or `unknown`.
Classification precedence is running, repair, human input, provider/scheduler,
completion, unknown, then idle. The human renderer deliberately displays
running, human input, repair, provider/scheduler, completion, unknown, then
idle; it caps each band at five rows and reports overflow with `hive status
--full`. The human view prints active/archive counts, exact project/slug
identity, stage/marker, blocker owner, reason, and source issues. The JSON
document additionally carries project counts, daemon/scheduler identity and
freshness, and structured provider/retry evidence.

A benign dependency-blocked row is always
`waiting_on_provider_or_scheduler`, with `blocker_owner: scheduler` and
`dependency_wait` as its primary reason; it cannot fall through to `idle`.
Explicit human input still has higher precedence, so a row that is both
dependency-blocked and waiting for answers remains `waiting_on_you` while the
dependency reason stays secondary.

For a daemon-enrolled project with global automatic retry enabled, a real
`ERROR` or `REVIEW_ERROR` defaults to
`waiting_on_provider_or_scheduler` with `blocker_owner: scheduler`: Hive owns
the next guarded retry after its shared cooldown. A current daemon snapshot
refines that projection. `retry_cooldown` carries the exact deadline and stays
scheduler-owned; `retry_in_flight` is running/agent-owned; and
`retry_safety_blocked` becomes `needs_repair` with the reported operator or
Hive owner instead of falsely claiming the scheduler will clear it.
Disabling either the project daemon or global automatic retry restores the
operator-owned `needs_repair` classification.

Completeness is explicit: `complete`, `partial`, or `unknown`. Missing project
roots, legacy stage directories, invalid task metadata, unavailable/stale
scheduler evidence, or a failed scheduler join cannot silently collapse into
an idle verdict. Unclassifiable rows remain `unknown`; a partial snapshot may
still report a stronger directly observed active state, but never claims idle
from missing evidence.

`hive-operational-status.v2` includes summary/state counts, daemon identity and
phase, scheduler capacity/queue/provider holds, archive counts, typed issues,
per-task liveness/freshness, blocker ownership and reasons, nullable retry
evidence (`due`, `retry_at`, `safe`, `safety_reason`), and an optional closed
action descriptor plus the canonical durable recovery receipt. It never embeds
a shell command or argv. A routine,
confirmation-free recommendation carries `action_id`, exact `project:slug`, an
observation token, risk class, and provenance; execute it only with:

```bash
hive act workflow.advance PROJECT:SLUG --observation TOKEN --json
```

Recoverable rows instead recommend `workflow.retry` with the same token
contract. `hive-act.v2` returns the canonical queued/cooldown/running/blocked/
terminal recovery receipt. The one-off recovery-contract migration moved every
in-repository producer, consumer, fixture, and operating skill to v2; v1 is no
longer published or supported.

Recovery recommendations bind to the exact current `marker_id`. A task carrying
an old id-less recoverable marker reports `recovery_migration_required` and
remains operator-owned until `hive migrate <project>` performs the one-off
identity upgrade. Status and act never derive a recovery identity from marker
mtime, reason, or another low-cardinality attr.

`hive act` resolves and locks the task again, recomputes the permitted verb,
and rejects stale tokens or recommendations that are no longer routine. It is
not a general command executor and cannot represent destructive, release, or
administrative actions.

For markerless descriptor tasks, `observation_mtime` and the locked recheck use
the stable task `meta.yml` mtime when present rather than the task-directory
mtime. Task lock creation changes the directory mtime, so using it would make a
freshly issued generic `ready_to_run` action reject itself after acquiring its
own lock. The compatibility `mtime` keeps its state-file-or-directory meaning
so daemon dispatch baselines still observe stage moves. Real-command tests
cover workflow stage actions plus generic `run` and `approve` branches from
status-issued tokens.

Full text/JSON status and daemon snapshots read the complete on-disk graph.
The TUI's steady-state active-only refresh combines freshly parsed active
tasks with lossless immutable terminal task snapshots from its last
full/archive status pass. Those snapshots preserve exact workflow stages,
dependency edges, validation errors, and enrolled repository identity. They
are indexed once and reused as a fallback context, keeping refresh cost
independent of archive size without changing transitive dependency verdicts.

The JSON envelope isolates project-local failures. Missing roots report
`error: missing_project_path`, missing state roots report
`error: not_initialised`, and an unexpected project load/projection exception
reports `error: project_load_failed`; each degraded project has an empty task
array while healthy projects remain present. The machine-readable error keeps
an unexpected failure distinguishable from a legitimately empty project, with
the detailed exception retained in the stderr/daemon-log breadcrumb.
`UnsupportedProjectConfigError` is the deliberate exception to project-local
degradation: text, compatibility JSON, and operational status all propagate the
shared configuration failure (exit 78) instead of returning an `ok: true`
snapshot that hides unsupported root keys.

## Detailed compatibility output shape

The following detailed grouping and row rules apply to `--full`, archive mode,
and the unchanged compatibility JSON where relevant.

```
<project_name>
  Ready to brainstorm
    ⏸ #42  —     Add inbox filter      waiting                  hive brainstorm add-inbox-filter-260424-7a3b 2h ago
  Ready to develop
    ✓ #43  #561  Refactor auth flow    complete                 hive develop refactor-auth-260423-1c2d 1d ago
  Agent running
    🤖 —    —     add-cache-260424-9a8b agent_working pid=1234   - 5m ago
```

`hive status` prints one block per project. Action buckets without active tasks are skipped. Within a bucket, rows are sorted by task mtime (newest first). The human identity column renders `#id PR display_name` when available, falls back to `#id PR slug`, and uses `— PR slug` when pre-migration/counter-failed tasks have no id. The PR slot is fixed-width: rows with no parseable PR URL render `—`, while pull-request URLs render `#<number>` and become OSC 8 hyperlinks only when stdout is a TTY. Commands and internal paths continue to use the slug. Raw slug, id, display name, stage, folder, and timestamps remain available in `--json`. JSON rows include `mtime` (state-file mtime when present, otherwise the directory mtime), `observation_mtime` (the stable action-token source: state file, then `meta.yml`, then directory), and `folder_mtime` (always the task-directory mtime). All three timestamps are ISO8601 with six fractional digits. Keeping the scheduler-facing `mtime` distinct from the action-facing `observation_mtime` lets stage moves invalidate dispatch baselines without letting lock-directory churn invalidate an action token. `folder_mtime` remains useful for consumers that need folder-level aging, especially archived task rows where the terminal marker file may not reflect later directory-level activity.

Rows also include `workflow`, the descriptor id that resolved the task (`"coding"` for legacy/default rows, or the `meta.yml workflow:`/project default id for registered non-coding tasks). Row-based consumers such as the daemon and Telegram bot use it to keep coding-only plan/brainstorm/review/finalize behavior from firing for generic tasks.

Rows also include `pr_url`: coding tasks expose it from `5-open-pr` onward,
while any workflow declaring `handoff: draft_pr` exposes it as soon as the
controller has written verified `<task>/pr.md` metadata. Status reads that
frontmatter through `Hive::Gh.pr_frontmatter` and emits a stripped non-empty
URL; before verification, or when `pr.md` is missing, blank, or malformed, the
field is `null`. This is a sibling task-payload field, not copied out of marker
attrs, so consumers do not need to scrape `<!-- COMPLETE pr_url=... -->`.

Condition-aware rows add `condition_task_generation`, `commit_generation`,
`current_attempt`, `conditions`, `condition_history`, `evidence`,
`condition_gate`, `condition_migration`, `condition_provenance`,
`condition_overrides`, `shadow_audit`, and `condition_warning`. Existing marker/action/attrs fields
stay stable. Status reads the one canonical [[modules/conditions]] projection;
daemon, TUI, bot, and web pass through that payload instead of deriving their
own condition semantics. Snapshot validation or journal replay is read-only:
status never observes git/GitHub, creates a baseline/audit, or publishes a
repaired snapshot.

These fields and the `project_load_failed` project error are published as
`hive-status` v6. The existing `task_generation` compatibility field remains
the opaque durable ownership token (string or null); the numeric condition
epoch is `condition_task_generation`. The v5 schema remains unchanged for
stored-output and rolling-consumer compatibility.

JSON rows also include `next_action`; it is usually `null`, but legacy
`EXECUTE_WAITING reason=...` and condition-authoritative blocked rows carry the
same structured recovery target that run/approve/workflow-verb JSON errors
emit. Pending evidence uses `kind=no_op reason=condition_reconciliation_required`;
attempt loss/failure uses `kind=run`; worktree/evidence repairs identify an
editable target. `condition_overrides` contains the latest 20 forced gate
waivers with source command and waived diagnostics; the journal retains full
history. Every JSON row also includes `diagnostic`; it is `null` for ordinary rows and a bounded red-row payload for `recover_execute`, `recover_review`, and `error` rows. JSON rows carry `unanswered_questions` (issue #270): the count of still-unanswered `### Q{n}.` slots for a `2-brainstorm` `needs_input` row, and `0` otherwise.

Every task row has `depends_on`, `blocked_by`, `dependency_stage`, `blocked`, and required nullable `admission_error`. The correlations are closed:

- clear: `blocked: false`, ordinary wait fields null, `admission_error: null`;
- benign wait: `blocked: true`, `blocked_by`/`dependency_stage` populated, `admission_error: null`;
- admission error: `blocked: true`, ordinary wait fields null, action `admission_error`, `suggested_command: null`, and an object containing exactly `reason_code`, `offending_ref`, `safe_correction`.

Text/TUI render a benign wait as `⏸ blocked by <task> (<stage>)`. Admission errors render the stable reason and safe correction ahead of ordinary waits and are never described as waiting on an in-flight task. An unexpected validator exception becomes `dependency_validation_failed`, never an unblocked row.

### Implementation ownership

Coding task rows may also carry `implementation_identity`: the numeric generation, a pending flag, and stage entries for `execute`, `open_pr`, `review.fix`, and `review.ci`. Resolved entries come from projected journal launch events; unlaunched downstream entries are read-only previews from the persisted execute owner plus raw override provenance. Each entry exposes provider, concrete model, requested/effective effort, support, source (`persisted_execute`, `explicit_override`, or `legacy_backfill`), attempts, and resolved/preview status. Unsupported effort is rendered as requested but not applied.

Repeated CLI/TUI/web status reads never reconstruct legacy ownership or append journal events. Text and TUI rows append a bounded execute-owner token after primary error/dependency signals; `I` opens the TUI's full four-stage table, and Hivebox task details show the same projection.

## Archived tasks

`Hive::ArchiveFilter` is the shared policy for day-to-day archive hiding. A row is hideable when `stage == Hive::Stages::DIRS.last` (`9-done`), the row timestamp is present, and `(now - mtime) > 3 days`. Marker state is not part of the policy: complete, unresolved, and markerless done rows all use the same age rule. The policy uses the task row's `mtime` (state-file mtime, the same timestamp rendered as row age) rather than `folder_mtime`, because sidecar updates such as `meta.yml` display-name backfills can touch the directory without making the archived task newly relevant. Older consumers that only have `folder_mtime` still get it as a fallback. If neither timestamp is available, the filter fails open and keeps the row visible rather than guessing. `hive archive` remains the full view.

The age filter applies to the TUI grid and the detailed `hive status --full`
human table. `hive status --json` stays unfiltered so daemon, bot, TUI, and
pinned consumers continue to see every task row. The operational projection
does not emit archived task rows; it reports archive totals by project in
its `archive` summary. Use `hive archive` for archived row details.

`hive archive` with no target reuses Status in archive mode (`Hive::Commands::Status.new(archive: true)`): it lists only `9-done` tasks, with no age cutoff and no hidden-count summary. Empty archive projects print `no archived tasks`. Text rows are sorted newest-first by `mtime` and use the same id/PR/display-name identity column as daily status. `hive archive --json` emits a focused `hive-status` payload whose project task arrays contain only `9-done` rows. `hive archive <slug>` still runs the workflow verb that advances a completed finalize task into done.

Every compatibility JSON task row has a nullable `closure` field. A validated
receipt exposes the exact reason, authority, digest, successor, and canonical
evidence links; an invalid receipt exposes a bounded quarantine blocker and
never overrides the current task state. Archived rows retain that same receipt,
so a missing worktree or empty diff remains explainable.

Operational active rows include a typed closure block. With no receipt its
status is `operator_required` and it advertises
`workflow.close_with_evidence` as `confirmation_required: true`. That
descriptor deliberately has no observation token and is absent from
`OperationalAction::ACTION_IDS`; `hive act` cannot execute it. A receipt
written before a crash appears as `confirmed_pending_transition`. The archive
summary includes compact closure receipts for delivered/superseded tasks while
continuing to omit ordinary archived rows.

## Legacy stage directories (`legacy_stage_dirs`)

Every Project entry in `hive status --json` carries a `legacy_stage_dirs` array — `[]` for healthy projects, otherwise a list of `{ "stage_dir": "<name>", "task_count": <N> }` entries (sorted alphabetically by `stage_dir`). The field is populated by `Status#detect_legacy_stage_dirs`, which scans `<hive_state>/stages/` for directories that are **not** in `Hive::Workflows.all_stage_dirs`, are not status-private siblings such as `archived-manual/`, and contain at least one slug-shaped task subfolder (per `Hive::Stages.task_slug?`, the same predicate `hive migrate` uses to decide which entries it is allowed to mv — so the count reflects what `hive migrate` would actually move). Stray non-slug siblings (`logs/`, `.gitkeep`, `.DS_Store`) are ignored.

When the field is non-empty, the text output prints a warning under the project header:

```
<project_name>
  ⚠ 2 tasks hidden in legacy stage dirs: 5-review (1), 6-pr (1)
    run `hive migrate` to move them into the current layout
```

The warning is singular for one hidden task (`1 task hidden`) and plural otherwise. The TUI projects pane mirrors the warning by prefixing the affected project's name with `⚠` and the short hint `legacy dirs — run hive migrate`. The Telegram bot also sends a proactive project-level notification on the clean-to-legacy transition, deduped by the bot alert store while the project remains legacy-dirty, even if the hidden task count changes. Bot messages include a project-path-scoped `hive migrate <project_path>` command because the bot is global. Running `hive migrate` moves the slugs into the canonical stage directory listed in `Hive::Commands::Migrate::STAGE_RENAMES`, and after the next status poll the warning disappears.

The `legacy_stage_dirs` field was an additive extension of status v2. Task `id` / `display_name` fields produced v3; dependency waits produced v4. Fail-closed admission is `hive-status` v5, with required nullable `admission_error` and closed reason/action enums; condition fields and isolated projection failures produce v6. Historical v4/v5 schemas remain available. An older daemon safely ignores an admission-error row because it is both `blocked: true` and carries the unknown inert `admission_error` action with no command.

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
- Old `9-done` rows → hidden from `--full` text output by age alone,
  regardless of marker state, with the per-project summary line above.
- Daily and archive-mode task identity is left-padded to 49 chars; it includes id, fixed-width PR token, and display name/slug. State label is left-padded to 24 chars, followed by the suggested command and humanised age. Marker attr values in the state label collapse internal whitespace so multi-line stderr details do not break the table.

`humanise_age` thresholds: `<60s → Ns ago`, `<3600s → Nm ago`, `<86400s → Nh ago`, else `Nd ago`.

## How tasks are discovered

For each stage in `Hive::Workflows.all_stage_dirs` (the union of every live registered descriptor; coding remains the default source of truth via `Hive::Stages::DIRS`), `collect_rows` globs `<hive_state>/stages/<stage>/*` directories through the `stage_task_entries(stage_dir)` seam. Each entry is parsed via `Hive::Task.new(entry)`; non-conforming directories (no slug match, or a folder whose `workflow` selector does not contain that stage) are silently skipped via `rescue InvalidTaskPath`. Marker is read with `Hive::Markers.current(task.state_file)`. `folder_mtime` is always `File.mtime(entry)`; `mtime` is the state-file mtime when the state file exists and otherwise the directory mtime; `observation_mtime` is the state-file mtime when present, then `meta.yml`, then the directory fallback.

Stage moves are treated as a normal filesystem race. If an entry disappears between the stage glob and any in-folder row read, `collect_rows` rescues `Errno::ENOENT`, re-checks the folder path, and skips it only when the folder is gone. The rescue is deliberately folder-level: an `ENOENT` while the task folder still exists is re-raised as a real status command failure, because in-place state-file writers may truncate content but should not make the state file transiently absent inside a surviving folder. A forward stage move can resurface under the later stage in the same scan; a backward move to an already-scanned stage can disappear for one poll and then reappear on the next refresh. After all stages are scanned, `drop_transient_stage_moves` looks only at duplicate-slug groups and removes every duplicate row whose folder no longer exists. If two live folders still share a slug, both rows remain and `annotate_actions` still passes `stage_collision: true` into `Hive::TaskAction`. This keeps `hive status --json` and TUI snapshots from briefly showing an old-stage and new-stage copy during a normal `mv`, without hiding persistent duplicate state.

Rows are then classified by `Hive::TaskAction`, which emits an action key, label, suggested command, and optional row-local `next_action` such as `kind=edit target=<worktree>` for dirty execute worktrees or `kind=run` for `missing_research_output`. `collect_rows` also reads each task `.lock`, verifies the holder PID and recorded process start time through `Hive::Lock`, and passes `live_task_lock: true` to `TaskAction` while `hive run` is active even if the stage has not written an `AGENT_WORKING` or `REVIEW_WORKING` marker yet. If one project has the same slug in multiple stages, workflow commands include `--from <stage>` and generic findings commands include `--stage <stage>`.

## Red-row diagnostics

`TaskAction#diagnostic` is the local source for red status rows. It returns:

- `summary` — marker name plus marker attrs, truncated and secret-redacted.
- `detail` — the tail of the best matching artifact, or marker fallback text when no artifact exists.
- `source` / `source_path` — whether the detail came from an artifact or marker fallback.
- `artifact_paths` — every relevant artifact discovered for this marker.
- `generated_by` — `local` for bounded extraction, or one of the schema-listed diagnose generators (`claude`, `codex`, `pi`, `grok`) that wrote a fresh diagnosis artifact.
- `updated_at` — mtime of the source artifact or marker state file.

Artifact discovery is marker-specific. Review errors prefer `diagnostics/red-status.md` when it matches the current marker, then pass-specific files such as `reviews/errors-NN.md`, `reviews/fix-guardrail-NN.md`, `reviews/escalations-NN.md`, marker `files=...` entries, phase logs, and latest logs. `review_ci_stale` includes `reviews/ci-blocked.md` and CI-fix logs. `review_stale` includes the pass escalations/reviewer files. `execute_stale` includes review files and logs. Generic `ERROR` includes recent logs and the task state file.

Fresh agent-written diagnostics live at `<task>/diagnostics/red-status.md`. Normal status trusts that file only when:

- frontmatter parses;
- `generated_by` is in `Hive::Schemas::DIAGNOSTIC_GENERATORS` (`local`, `claude`, `codex`, `pi`, `grok`);
- `marker_signature` matches the current marker name plus sorted attrs.

That signature check prevents a stale diagnosis from explaining a new failure after the marker changes.

## `--diagnose`

```
hive status --diagnose <slug-or-folder> [--project <name>] [--stage <stage>] [--json]
hive status --diagnose <slug-or-folder> [--project <name>] [--stage <stage>] --write [--json]
```

Without `--write`, `--diagnose` resolves the target via `Hive::TaskResolver` and is read-only. For a **red-recovery** row it prints the same local diagnostic payload `hive status --json` carries on that row. For any **other** row with evidence on disk it diverges deliberately: where `hive status --json` reports `diagnostic: null` because the field doubles as a health signal there, `--diagnose` can synthesize a non-null diagnostic through `Hive::DiagnosticEvidence`. So `diagnostic == null` is not a health signal on this surface.

`Hive::DiagnosticEvidence` fills the nil-diagnostic gap in tier order: `diagnostics/red-status.md` (a prior agent verdict), then the newest meaningful `logs/*.log` line by mtime, then the current marker on the task state file. It checks both in-folder `logs/` and the inferred global per-task log directory `.hive-state/logs/<slug>/`, derived from `Hive::Task::PATH_RE`. The result carries an explicit source label (`Diagnostics:`, `Log:`, or `Marker:`). The resolver is best-effort and must not block or raise: it refuses non-regular files, refuses symlinked evidence that escapes the trusted roots, byte-caps marker reads, catches deep YAML parse failures, and degrades to `nil` when evidence is unusable.

With `--write`, `Hive::DiagnosisAgent` uses the configured development profile (`execute.agent` via `Hive::Stages::Base.stage_profile`) to produce a concise markdown diagnosis, then atomically writes `<task>/diagnostics/red-status.md`. Defaults are `timeout_sec.diagnose || 600` and `budget_usd.diagnose || 5`. The agent gets the task folder as an add-dir and runs from the task worktree when one exists, otherwise the project root. The worktree pointer is validated against the configured worktree root before it is used as cwd. Custom execute profiles are rejected for diagnose unless their `generated_by` value has first been added to `Hive::Schemas::DIAGNOSTIC_GENERATORS` and the published schemas. The command does not claim the task lock and does not write workflow markers.

JSON output uses schema `hive-status-diagnose`, version `2`, and returns `slug`, `id`, `display_name`, `task_folder`, `diagnostic`, and `path` (set only when `--write` wrote an artifact).

## Read-only

Normal `status` and `status --diagnose` without `--write` do not mutate filesystem state, do not commit, do not spawn agents, and do not touch locks. `status --diagnose --write` is the explicit mutation path: it spawns the configured development agent and writes only `diagnostics/red-status.md`.

## Tests

- `test/integration/status_test.rb` — empty registry, action grouping, suggested commands, stale-lock decoration, and v5 admission fields.
- `test/integration/dependency_admission_test.rb` — plan-only ordering drift and cross-project repository identity mismatch.
- `test/unit/commands/status_test.rb` — status row collection, per-project `project_load_failed` degradation, vanished-folder and transient duplicate stage-move races, non-finalize forward moves, state-file `ENOENT` re-raise when the folder survives, multi-row duplicate pruning, genuine collision preservation, corrupted finalize rows, legacy dir warnings, live task-lock action override, `folder_mtime` JSON emission, `pr_url` extraction from `pr.md` frontmatter, text/archive PR-column rendering, old-archive hiding, and archive-mode listing.
- `test/unit/operational_status_test.rb` — closed state projection, source
  completeness, scheduler joins/freshness, archive summaries, and schema.
- `test/unit/operational_action_test.rb` and
  `test/unit/commands/act_test.rb` — closed action descriptors, token
  freshness, exact targets, safe dispatch, and stale rejection.
- `test/unit/commands/status_diagnose_test.rb` — local diagnose JSON, read-only `DiagnosticEvidence` fallback for non-red rows, schema validation of evidence payloads, and agent-written artifact refresh.
- `test/unit/diagnostic_evidence_test.rb` — evidence-tier ordering, source labels, newest-log selection, global log-dir inference, marker-tier fallback, redaction/truncation, invalid UTF-8 handling, symlink/regular-file safety, never-raise degradation, and deep YAML hardening.
- `test/unit/task_action_test.rb` — diagnostic extraction, redaction, artifact selection, marker fallback, non-red nil.

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]] · [[commands/watch]]
- [[modules/markers]] · [[modules/task]] · [[modules/task_action]] · [[modules/task_dependencies]] · [[modules/config]]
