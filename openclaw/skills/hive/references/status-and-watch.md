# Status and watch

## Choose the status surface

- Use `hive status` for a concise human snapshot.
- Use `hive status --operational --json` for agent decisions. It emits `hive-operational-status.v1`.
- Use `hive status --json` only when a consumer needs the compatibility `hive-status.v6` full graph.
- Use `hive status --full` for the detailed human table.
- Use `hive daemon status --json` for daemon process health. Do not substitute daemon health for task or scheduler truth.

Operational status is a projection over one full task graph. A current daemon observation may add scheduler ownership, capacity, queue, provider-hold, cooldown, and recovery facts. Only a complete, unexpired observation from the live daemon generation is current. Missing, stale, invalid, or mismatched scheduler evidence lowers completeness and must not become a confident blocker claim.

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
