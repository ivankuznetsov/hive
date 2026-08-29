# Status and watch

## Choose the status surface

- Use `hive status` for bounded daemon health and currently live tasks.
- Use `hive status --json` for the same bounded `hive-running-status.v1`
  projection in machine-readable form.
- Use `hive status --operational --json` for agent decisions. It emits `hive-operational-status.v4`.
- Use `hive task TARGET --project NAME --json` for one task's semantic result,
  primary artifact, applicable evidence, exact usage, API-equivalent estimate,
  and receipt-correlated diagnostic-log reference.
- Use `hive task TARGET --project NAME --log` only after that diagnostic is
  current; it re-resolves and integrity-checks the current receipt reference
  before printing a bounded tail.
- Use `hive daemon status --json` for daemon process health. Do not substitute daemon health for task or scheduler truth.
- Use `hive circuits inspect --json` for the shared provider-account/model health, capacity, and routing-decision projection. Add `--provider ACCOUNT` or `--model MODEL` to keep accounts and decisions in the same scope.

Operational status is the public fleet workflow projection. A current daemon observation may add scheduler ownership, capacity, queue, provider-hold, cooldown, and recovery facts. Only a complete, unexpired observation from the live daemon generation is current. Missing, stale, invalid, or mismatched scheduler evidence lowers completeness and must not become a confident blocker claim.

Always inspect the required `attempt_storage` cell. If it is `degraded`, report
its `degraded_reason` and last error operation as a Hive-owned migration or
maintenance fault; do not call the pipeline healthy merely because task rows
are advancing. `unknown` means the bounded health cell has not yet established
a successful migration or maintenance result.

When a task is `needs_repair`, inspect `evidence.marker_attrs`. A reason of
`condition_projection_repair_required` means routine status could not verify
that task's checkpoint and bounded journal suffix. The row is synthetic,
operator-owned, and non-retryable; it does not mean the project or fleet scan
failed, and unrelated tasks may continue. Run the exact
`evidence.marker_attrs.repair_command` when present:

```bash
hive repair-projection TASK-SLUG --project PROJECT --stage STAGE
```

Refresh operational status afterward. Do not use `workflow.retry`, restart the
daemon, or create migration/watcher machinery. If no repair command is present
and `projection_reason` is `checkpoint_oversized`,
`attempt_ids_exhausted`, or `predecessor_fetches_exhausted`, report the named
`projection_cap` and task-local retained-history compaction requirement.

## Report a useful snapshot

Lead with the outcome:

```text
SNAPSHOT <complete|partial|unknown> — <active> active · <archived> archived
<project:slug> · <state> · <blocker_owner> — <reason>
```

For status questions, include:

- Counts and overall completeness.
- The exact active `project:slug`, workflow position, and live state.
- The exact blocker owner and reason.
- Provider name and `retry_after` only when current evidence provides them.
- The current scheduler gate or capacity reason when that is the owner.
- A clear distinction between verified facts and unavailable or stale evidence.

Do not dump every compatibility field unless asked. Do not call a generated row publishable, complete, or archived unless the corresponding workflow evidence proves that state.

## Inspect one task and diagnose from its log

After operational status identifies the exact task, inspect its operator-facing
meaning without scraping Web HTML:

```bash
hive task TASK-SLUG --project PROJECT --json
```

Read `headline` and `action` as canonical task posture; read `result.primary`
as the workflow's current work product; read `applicability` before expecting
worktree, diff, publication, media, dependency, or supporting-artifact evidence.
Usage keeps harness, actual provider/model, and launch-bound billing route
separate. Treat `api_equivalent` only as a coverage-labelled estimate against
the local public API rate catalog. `partial`, `pending`, `unavailable`, and
`unknown` are evidence states, not zero.

When `diagnostic.state` is `current`, prefer
`diagnostic.log.reference` because it came from the exact attempt receipt.
Resolve and read it through Hive's trusted task path:

```bash
hive task TASK-SLUG --project PROJECT --log
```

The command re-resolves the current semantic reference and reads only its
integrity-checked bounded tail. Do not open the reference path yourself, choose
a log by newest-file mtime, or use raw
`agent_start`, `agent_end`, session-lifecycle, or stage-transition events as a
substitute for the task's result or the correlated failure log.

The task view does not probe providers and does not reconcile invoices. Never
infer live provider health, quota, credential validity, actual subscription or
API charge, or provider-observed billing from it. Use current operational
scheduler evidence for task ownership and `hive circuits inspect --json` for
the dedicated provider-account/model health projection.

## Watch selected work

Use Hive’s observer:

```bash
hive watch PROJECT:SLUG --until settled --json-lines
hive watch SLUG --project PROJECT --until completion --json-lines
hive watch --project PROJECT --timeout 900 --max-events 50 --json-lines
```

Targets resolve once. A qualified `PROJECT:SLUG` is exact; a bare slug must be globally unique or scoped with `--project`. Project-only selection captures current non-archived tasks and never silently adds later tasks. At most 100 targets are selected.

Defaults are a 15-second interval, 1,800-second timeout, and 100 non-final events. Every normal boundary reserves one additional `final` event. `--until settled` ends when every target needs a human decision, needs repair, or is completion-ready. `--until completion` requires verified workflow completion or a matching archived identity. Disappearance is a warning, never completion.

`--json-lines` is the only machine stream. Each line independently validates as `hive-watch-event.v1`. The global `--json` document mode is invalid for watch. Meaningless timestamp and age churn is suppressed; material state, owner, reason, position, provider, freshness, liveness, terminality, and action-policy changes emit transitions.

Timeout and event-cap finals are successful bounded observations. Three consecutive source failures or unexplained absences end as status unavailable. SIGINT and SIGTERM preserve exit 130 and 143 after a final event. A closed downstream pipe exits cleanly. Watch never owns workers or changes task state.
