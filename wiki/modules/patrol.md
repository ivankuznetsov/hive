---
title: Hive::Patrol
type: module
source: lib/hive/patrol/, lib/hive/refactor_patrol/, lib/hive/patrol_fix/, script/migrate_patrol_findings.rb
created: 2026-05-28
updated: 2026-08-21
tags: [module, patrol, architecture, workflow]
---

**TLDR**: Ordinary Patrol and Architecture Patrol are discovery systems. They
write their own native findings/jobs and reserve accepted work directly in the
shared `patrol-fix` `AdmissionStore`. They do not fix code, open issues, or
publish pull requests. There is no Patrol module cutover, shadow comparison,
occurrence journal, effect delivery layer, or runtime migration subsystem.
Historical ordinary findings can be imported once with
`script/migrate_patrol_findings.rb`.

## Runtime shape

```text
ordinary review ──> StateStore finding ──> FixAdmissionAdapter ──┐
                                                               ├─> AdmissionStore ─> patrol-fix task
architecture review ─> JobStore disposition ─> FixAdmissionAdapter ─┘
```

The adapters translate accepted source bytes into one strict
`PatrolFix::SourceSnapshot` and call `AdmissionStore#reserve!` directly.
Reservation is idempotent by occurrence identity and source digest. The
admission scheduler decides whether a source matches an existing task root or
needs a new task, records materialization intent, binds the durable task, and
only then acknowledges the source.

No intermediate handoff outbox or project-level Patrol Fix operational
projection exists. Patrol Fix tasks use the normal task graph, daemon capacity,
status, TUI, bot, and Watch contracts.

## Ordinary Patrol

`Hive::Commands::Patrol` maps a freshly fetched default-branch revision,
reviews a bounded rotating feature batch, validates evidence, and persists
immutable findings under:

```text
<hive_state_path>/patrol/
├── state.json
├── findings/*.json
├── runs/
└── logs/
```

`Hive::Patrol::StateStore` owns only ordinary Patrol state. It does not own
cross-product occurrences, effect receipts, migration epochs, or projection
outboxes. The daemon scheduler decides cadence from the configured trigger,
reserves a direct cycle lock, and launches `hive patrol PROJECT --json`.
Successful or failed child completion updates scheduler backoff only; the
command persists the authoritative finding and scan state.

## Architecture Patrol

Merged-PR intake and scheduled architecture review remain separate discovery
sources:

- the merge reconciler classifies merged PRs and freezes accepted work into
  bounded post-merge batches;
- the scheduler materializes each batch directly into a v4 JobStore aggregate;
- scheduled slice production reviews one pinned architecture slice and reserves
  accepted findings directly in Patrol Fix;
- JobStore discovery claims, checkpoints, cooldowns, and retirement remain the
  sole lifecycle authority.

Current state is split intentionally:

```text
<hive_state_path>/refactor_patrol/
├── v2/
│   ├── reconciler.json
│   ├── reconciler-progress.json
│   ├── merge-classifications/
│   ├── post-merge-batches/
│   ├── manifests/
│   ├── results/
│   ├── runs/
│   └── logs/
└── v4/
    ├── jobs/
    └── indexes/job-query/
```

The immutable `occurrence_id` and `intake_transition_id` fields in a v4 job
are direct aggregate identities. They are not pointers into an occurrence
journal and do not authorize a migration or replay lane. New intake derives
both IDs deterministically from the job ID and manifest checksum.

V3 JobStore bytes remain opaque. There is no runtime reader, converter, reset,
archive, restore, or fallback path. A fresh project creates v4 state on its
first authoritative mutation; read-only queries do not create state.

## Scheduling and capacity

Patrol is opt-in and coding-workflow-only. Ordinary and Architecture scheduled
discovery have separate per-project, per-engine daily launch allowances.
`UsageDb` is telemetry, not admission authority. Provider resource exhaustion
parks only the affected lane.

The Patrol arbiter alternates ready ordinary and architecture candidates under
`daemon.max_concurrent_patrol_scans`. Candidate discovery is read-only;
reservation revalidates current project registration/configuration and acquires
the native store claim immediately before dispatch.

Architecture discovery claims retain PID, process-start-time, process-group,
lease, heartbeat, owner, and generation. A stale generation cannot checkpoint.
A new daemon may reclaim a dead exact process; live or unverifiable ownership
remains fenced.

## Patrol Fix and publication

Patrol Fix owns the repair workflow:

1. Inbox re-investigates the current source and makes the semantic admission
   decision.
2. Fix creates or recovers one exact local worktree generation.
3. Validate runs only configured or structured validation commands.
4. Review records an independent route decision.
5. Publish uses `Hive::GithubPublication`.

`Hive::GithubPublication` is the single PR-publication mechanism used by
Patrol Fix and the normal coding open-PR path. It owns durable push/create
intent, remote reconciliation, expected-absence leases, and exact hosted
observation. Discovery code has no remote mutation authority. Escalation creates
one linked standard coding task through `TaskCapture`; it does not create a
GitHub issue.

## One-time historical import

`script/migrate_patrol_findings.rb [PROJECT_ROOT] [--dry-run]` reads active
ordinary findings from the local native StateStore and creates ordinary
`patrol-fix` tasks through `TaskCapture`. It is the only Patrol migration
path. It has no daemon hook, timer, module owner, cutover state, rollback,
qualification report, or compatibility reader.

The importer is idempotent by
`patrol-fix:legacy-finding:<finding-id>`. Matching existing tasks are reused;
conflicting matching metadata fails closed. Unrelated malformed task metadata
is ignored.

## Read models

The web Patrol page reads bounded `FindingQuery` and `JobQuery` results
directly. The two lanes fail independently and expose no mutation controls.
Patrol Fix contributes no project-level status schema; its tasks appear through
the standard task projections.

## Safety invariants

- Discovery and repair are separate: accepted findings only reserve workflow
  admission.
- Source acknowledgement occurs only after a durable task binding exists.
- Ordinary and Architecture stores remain independent native authorities.
- No scheduler, command, doctor, status, TUI, bot, or web path consults Patrol
  migration ownership or shadow evidence.
- No legacy Patrol fixer, issue filer, PR opener, review handoff, action runner,
  or publication engine is runnable.
- Remote PR publication goes through `Hive::GithubPublication`.
- Historical import is explicit, local, one-time, and never daemon-triggered.

## Backlinks

- [[commands/patrol]]
- [[commands/refactor-patrol]]
- [[modules/daemon]]
- [[state-model]]
- [[testing]]
