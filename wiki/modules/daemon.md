---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-07-26
tags: [daemon, module, automation, dispatcher, operational-status, snapshots]
---

**TLDR**: Small modules under `Hive::Daemon::*` that together form
the auto-advancing dispatcher (ADR-024). Pure logic (`Policy`,
`ConcurrencyController`) is separated from I/O (`StatusConsumer`,
`ChildSupervisor`, `Logger`, `PrMergeWatcher`, `AnswerDigestScheduler`,
`StaleAgentHealer`, `DisplayNameBackfiller`) so
the safety-relevant decisions are unit-testable without forking. Task-stage
agents are detached durable attempts observed by the daemon;
`ChildSupervisor` owns ancillary work only. The daemon also owns merge intake,
fair scheduling, and fenced completion for the
language-neutral [[commands/refactor-patrol]] lifecycle. Each full tick also
publishes an owner-private, atomic operational snapshot. `hive status
--operational --json` and [[commands/watch]] join that scheduler evidence to
the task graph without making status itself perform daemon reconciliation.

`StatusConsumer` now passes through the additive condition projection fields
from `hive status --json`. Dispatch still consumes the canonical `action` and
diagnostic calculated by `TaskAction`; the daemon defines no condition family,
supersession, or gate rule of its own. Valid snapshots keep polling cheap, and
status polling never triggers reconciliation, git/GitHub probes, or journal
writes. See [[modules/conditions]].

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Daemon::Policy` | `lib/hive/daemon/policy.rb` | Pure switch over action, admission/dependency state, stage/workflow context, mtime debounce, and `answers_pending`. Structured admission errors return `:admission_error` before every stage branch; ordinary blocked rows cannot dispatch or poll for merge. |
| `Hive::Daemon::ConcurrencyController` | `lib/hive/daemon/concurrency_controller.rb` | In-memory budget gate: caps (global / per-project / per-day rate plus per-project patrol scans), WRONG_STAGE protective backoff, transient backoff schedule, quarantine, dropped projects, last-dispatched mtime tracking. `Dispatcher#reload_config!` applies reloaded limits through `update_limits` on this same object so SIGHUP changes admission immediately without discarding runtime state. SUCCESS exits do not cool down; the next stage may dispatch immediately. The last-dispatched mtime map is write-through-persisted via an injected `DispatchBaselines` store so it survives restart (see "Persisted dispatch baselines" below); everything else is intentionally in-memory. |
| `Hive::Daemon::DispatchBaselines` | `lib/hive/daemon/dispatch_baselines.rb` | Crash-safe JSON store for the `[project, slug] → state_file_mtime` baseline map (`daemon_dispatch_baselines.json` under the state home). Atomic write + fail-closed load; mirrors `Hive::UpdateCheck::State`. Stops answered `needs_input` tasks being re-stranded across a daemon restart. |
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed rows including `workflow`, canonical `pr_url`, and structured `admission_error`. Missing or malformed admission state is converted to `dependency_validation_failed`, `blocked: true`, action `admission_error`, and no command. Envelope shape is hard-validated while forward schema versions remain best-effort. |
| `Hive::Daemon::OperationalSnapshot` | `lib/hive/daemon/operational_snapshot.rb` | Private daemon-to-status observation channel. `Assembler` publishes `started`, `failed`, and revalidated `complete` tick records; completion time starts the validity window, SIGHUP recalculates it from the reloaded poll interval, and recovery receipts are overlaid only when task, stage, marker identity, and lifecycle still match. `Store` atomically persists records under owner-private path/inode checks; `Reader` accepts only the live daemon generation, complete phase, supported schema, and unexpired validity window, degrading every other condition to explicit unavailable/stale/invalid evidence. |
| `Hive::Daemon::StatusReport` | `lib/hive/daemon/status_report.rb` | Shared `hive-daemon-status` producer for `hive daemon status --json` and hivebox. Builds the PID/service/binary/update-nudge envelope as a plain hash, exposes `running_state`, `payload`, and web-safe `safe_payload`, bounds `installed_binary --version` probes to 10s, and owns `BINARY_DRIFT_STATES` / `BINARY_DRIFT_ACTIONABLE` so the CLI producer and web repair affordance read the same enum source. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Owns non-task ancillary children such as digest and patrol jobs. Task-stage agents use [[modules/attempts]] and are never adopted with `wait2` or terminated on daemon shutdown. Ancillary exits reaped during graceful shutdown are returned to the dispatcher and use the same scheduler-completion path as ordinary tick reaps. |
| `Hive::Conditions::AttemptObserver` | `lib/hive/conditions/attempt_observer.rb` | Observes reconciled terminal/lost durable attempts. For coding execute attempts it idempotently journals the current `AgentHealthy` fact and rebuilds the projection: only a terminal `succeeded` receipt is satisfied; failed/cancelled/lost outcomes fail closed. Confirmed deliveries are memoized in-process before task lookup/journal parsing; restart rechecks the durable journal once. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::RecoveryCoordinator` | `lib/hive/daemon/recovery_coordinator.rb` | Sole destructive authority for `ERROR`, `REVIEW_ERROR`, `REVIEW_STALE`, and `REVIEW_CI_STALE` recovery. It re-resolves task identity under the task lock, rechecks cooldown and safety, persists a generation-bound v4 request before clearing, and resumes `admitted → cleared → dispatched → terminal` after restart. User-facing adapters only submit observations and render its receipt. |
| `Hive::Recovery::API` | `lib/hive/recovery/api.rb` | Neutral adapter for CLI/action, TUI, Rails, recorder, Telegram, and healer observations. It normalizes each surface's row shape and derives the freshness token; `RecoveryCoordinator` still owns every policy decision and mutation. |
| `Hive::Daemon::PlanApproval` | `lib/hive/daemon/plan_approval.rb` | Safely turns daemon-enabled `3-plan` approval pauses into `hive develop ... --from 3-plan` dispatches by validating command shape and flipping `WAITING` to `COMPLETE`. |
| `Hive::Daemon::StaleAgentHealer` | `lib/hive/daemon/stale_agent_healer.rb` | Repairs stale `AGENT_WORKING` / `REVIEW_WORKING` ownership and is the sole automatic scheduler that submits cooled `ERROR` / `REVIEW_ERROR` observations to `RecoveryCoordinator`. Lease-backed attempt loss is ledger-only and dispatches successors through `Attempts::Dispatcher`; it does not project or clear a compatibility marker. |
| `Hive::Daemon::DisplayNameBackfiller` | `lib/hive/daemon/display_name_backfiller.rb` | Tick-time self-heal for tasks whose one-shot name generation at `hive new` never landed (agent/codex outage). It skips admission-error rows and uses `TaskMeta.read_for_admission`, so corrupt metadata is never treated as a blank name. For a healthy row whose `display_name` is nil/blank, it re-spawns fire-and-forget `hive generate-name <folder>`, mirroring `Hive::Commands::New#spawn_name_generator` (detached, pgroup, logged to `<state_home>/logs/display-name.log`, fully rescued). Anti-churn: an `@inflight` map stores `{pid, at}` per folder, uses the shared `Hive::ProcessKill.pid_alive?` `kill(0)` probe plus `MAX_INFLIGHT_AGE_SEC = 120` to avoid both double-spawns and reused-pid/EPERM pinning, `max_per_tick` (default 2) bounds spawns, and a set name is a natural fixed point. Unexpected row/reap/spawn errors degrade through `:fatal` logging while preserving the no-raise tick contract. Purely additive — never touches markers or dispatch. Logs `display_name_backfill`. |
| `Hive::Daemon::TaskIdBackfiller` | `lib/hive/daemon/task_id_backfiller.rb` | Tick-time self-heal for tasks created outside `hive new` (hand-made folder, one `mv`-ed in) whose `meta.yml` has no `id` — `hive new` allocates ids from `Hive::TaskCounter`, so a task that skipped it shows a blank id in TUI, status, and dependency refs. It skips admission-error rows and corrupt strict metadata reads, so allocating an id cannot replace damaged dependency evidence. For a healthy row whose `Hive::TaskMeta` `id` is nil it allocates `TaskCounter.next!`, writes it via `TaskMeta.update_id` (every other meta field preserved), and commits the meta on `hive/state` under the per-project commit lock (`Hive::Lock.with_commit_lock`, as every durable committer does) with the per-task `hive_commit(stage_name:, slug:, action: "id-assigned")` call. The `task_id_backfill` event carries `committed:` so a swallowed commit (lock timeout / git error) is visible rather than masquerading as fully durable. Synchronous (no spawn/inflight — assignment is instant), `max_per_tick` (default 5) bounds the per-tick commits, and an assigned id is a natural fixed point. Guards `File.directory?(folder)` first so a row that outlived its folder (e.g. `hive drop` between snapshot and tick) is NOT resurrected by `TaskMeta.write`'s `mkdir_p`. Row/commit errors degrade through `:fatal` / `task_id_backfill_commit_skipped` logging while preserving the no-raise tick contract. Purely additive — never touches markers or dispatch. Logs `task_id_backfill`. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Durable task-bound reconciler for every coding task with a PR in stages 5–8, including error rows. It verifies the registered repository, observed PR head, immutable reachable merge SHA, current task generation, ownership, and local worktree safety; checkpoints GitHub and architecture-intake receipts before the next side effect; then calls the same evidence-bound closure transition used by an operator. Registrations with a blank or `local:` repository identity are quietly skipped because merge reconciliation is not applicable; a real GitHub identity mismatch still fails closed. New `pr.md` metadata carries the controller-observed head; older tasks may recover it only from a strictly owned registered worktree. A merged PR without that binding stays `ambiguous` and active. `OPEN`, closed-unmerged, cross-repository, held, unsafe, and failing candidates remain in the ledger. One candidate per project advances per tick, and retry counts never evict work. |
| `Hive::Daemon::PrMergeReconciliationStore` | `lib/hive/daemon/pr_merge_reconciliation_store.rb` | Owner-private project-local `daemon/pr-merge-reconciliation.json` ledger. Schema v1 binds registration/path/repository/default branch and stores a backlog watermark, fair cursor, generation-keyed candidates, remote/architecture/archive receipts, holds, and uncapped failure counts with capped hourly backoff. Writes lock, atomically replace, and fsync; corrupt or identity-drifted bytes are preserved under `daemon/quarantine/pr-merge-reconciliation/` and block only that project. |
| `Hive::Daemon::RefactorPatrolMergeReconciler` | `lib/hive/daemon/refactor_patrol_merge_reconciler.rb` | Converges incremental exact-host GitHub catch-up and exact-PR intake into one checksummed, write-once manifest per repository/PR/merge occurrence. The task-bound reconciler gets the first intake opportunity each tick; repository catch-up then uses the remaining bounded deadline. Persisted GitHub backoff begins at observed failure time (tick wall anchor plus monotonic elapsed), not stale tick start. First enablement still seeds a current high-water baseline instead of importing history; the authoritative checkpoint remains schema v2. |
| `Hive::Daemon::RefactorPatrolMergeProgressStore` | `lib/hive/daemon/refactor_patrol_merge_progress_store.rb` | Crash-safe `reconciler-progress.json` sidecar for page cursors, accumulated merge identities, intake position, and GitHub retry state. It binds continuation to registration/repository identity plus the base v2 checkpoint fingerprint, writes atomically, fsyncs directory-entry changes, quarantines unsafe shapes/identity drift, and persists bounded exponential backoff with jitter. |
| `Hive::Daemon::RefactorPatrolScheduler` | `lib/hive/daemon/refactor_patrol_scheduler.rb` | Exposes oldest-first discovery/action candidates, validates exact registration and repository ownership, pins new discovery to the freshly fetched committed default branch, reuses a partial job's durable `analysis_sha` independently of the registered checkout, claims discovery with generation/liveness evidence, emits job-bound result paths, durably surfaces unavailable project config, and checkpoints only matching schema-valid completion envelopes. A clean quota-bounded batch checkpoints completed feature results with `complete: false` and no synthetic review error. Retryable failures normally use a 60-second backoff; revoked discovery or action authority is rechecked hourly because it requires a policy/configuration change, while a partial envelope whose every error proves a shared daily token limit, architecture review-launch limit, or architecture-only unmetered daily backstop is exhausted sleeps until the next UTC day. Architecture launch count follows the durable merge queue and is accounted separately from ordinary patrol's daily launch count; per-cycle capacity still bounds each child. |
| `Hive::Daemon::PatrolArbiter` | `lib/hive/daemon/patrol_arbiter.rb` | Shares each project's patrol-scan capacity between ordinary and architecture patrol and persists alternation state so either ready kind eventually runs. |
| `Hive::Daemon::DigestSchedulerBase` | `lib/hive/daemon/digest_scheduler_base.rb` | Shared daily-digest lifecycle: one pending date, cancellation, bounded failure backoff, dispatch envelope construction, observable tolerant state reads, and atomic cursor persistence. Concrete schedulers retain their cadence and cursor rules. |
| `Hive::Daemon::AnswerDigestScheduler` | `lib/hive/daemon/answer_digest_scheduler.rb` | Host-local daily answer reminder cadence. Persists `last_fired_date` in `<state_home>/answer_digest_state.json` and emits at most one `hive answer-digest --date D --json` child per day after the configured hour. |
| `Hive::Daemon::DispatchRequestQueue` | `lib/hive/daemon/dispatch_request_queue.rb` | File-backed delivery queue for all adapters. Runtime readers accept only current v4; the one-off state migration upgrades pending v1-v3 files before opening the queue. V4 adds restartable recovery phases, canonical task/marker/generation identity, owner/remediation, and terminal outcome/time. Requestors are validated against one closed adapter enum, including the explicit `operator` source. Nonterminal recovery requests do not expire; bounded request-keyed lock shards serialize claim, phase CAS, and pruning without accumulating one lock file per request. The dispatcher shares one pending/claimed scan between queue accounting and recovery projection per tick, and runs terminal recovery pruning at most hourly. Request IDs are bounded filesystem-safe identifiers. The single-dispatcher invariant remains: producers write, the daemon dispatches. |
| `Hive::Daemon::QueueDirectory` | `lib/hive/daemon/queue_directory.rb` | Shared `directory_for(dirname:, state_home:)` helper used by both dispatch queues so the owner-only (0700) per-queue directory invariant — the de-facto auth boundary for the dispatch channel — lives in one place (#253). |
| `Hive::Commands::Daemon` | `lib/hive/commands/daemon.rb` | Thor subcommand surface (`start` / `stop` / `status` / `reload` / `tail` / `install` / `enable` / `disable` / `queue`). Owns PID/signal lifecycle, service installation, per-project enrollment, and read-only dispatch-request queue inspection. A manual foreground or detached start fills an absent `HIVE_BIN` from `Hive::InvokedBinary`, keeping status probes, backfillers, and dispatched children on the same checkout/package as the daemon itself; an explicit operator/service override still wins. `queue` delegates to `Hive::Commands::Daemon::QueueCommand`. |
| `Hive::Commands::Daemon::QueueCommand` | `lib/hive/commands/daemon/queue_command.rb` | Extracted read-only queue-inspection surface (`hive daemon queue list/show/prune`) — touches only `queue_args`/`json`/`hive_home`, orthogonal to the daemon lifecycle, mirroring the `ServiceInstaller` extraction (#254). Internal IO/parse failures are wrapped in `Hive::InternalError` (exit 70). |
| `Hive::Commands::ServiceInstaller::ResultPresenter` | `lib/hive/commands/service_installer/result_presenter.rb` | Shared command-side service-install boundary for daemon and bot. It invokes their platform installer, preserves human outcome summaries, builds the service-specific success/error envelopes, translates drift/failure outcomes to the service-specific typed exceptions, and degrades hostile installer accessors safely while each command supplies only its label, schema, and error classes. |

## Wiring

```
hive daemon start
  └─ Hive::Commands::Daemon
       ├─ writes ~/Dev/hive/.daemon.pid
       └─ Hive::Daemon::Dispatcher.run_forever
            ├─ Hive::Daemon::Logger              (~/Dev/hive/logs/daemon.log, JSON-line)
            ├─ Hive::Attempts::Reconciler        (adopt/suspect/lost before admission)
            │    └─ Hive::Conditions::AttemptObserver (terminal/lost health journal)
            ├─ Hive::Attempts::Dispatcher        (shared task-generation admission)
            ├─ Hive::Daemon::ConcurrencyController
            ├─ Hive::Daemon::ChildSupervisor     (ancillary jobs only)
            ├─ Hive::Daemon::StatusConsumer      (Open3.capture3 hive status --json)
            ├─ Hive::Daemon::OperationalSnapshot (atomic scheduler observation)
            ├─ Hive::Daemon::DispatchRequestQueue (<state_home>/dispatch_requests/*.json)
            ├─ Hive::Daemon::RecoveryCoordinator  (durable guarded recovery)
            ├─ Hive::Daemon::PrMergeWatcher      (task-bound merge reconciliation)
            ├─ Hive::Daemon::PrMergeReconciliationStore (durable fair backlog)
            ├─ Hive::Daemon::RefactorPatrolMergeReconciler (incremental merge manifests/high-water)
            ├─ Hive::Daemon::RefactorPatrolMergeProgressStore (restart-safe page/intake cursor)
            ├─ Hive::Daemon::PatrolArbiter       (ordinary/architecture fairness)
            ├─ Hive::Daemon::RefactorPatrolScheduler (durable jobs/actions)
            ├─ Hive::Daemon::AnswerDigestScheduler (<state_home>/answer_digest_state.json)
            ├─ Hive::Daemon::StaleAgentHealer    (AGENT_WORKING repair)
            ├─ Hive::Daemon::DisplayNameBackfiller (missing display_name retry)
            ├─ Hive::Daemon::TaskIdBackfiller    (missing meta id assign)
            └─ Hive::Daemon::Policy              (pure decisions)
```

Lease-backed `attempt_lost` outcomes bypass marker recovery entirely.
`StaleAgentHealer#heal_attempt_losses` applies
verified orphan cleanup and dirty capture, then dispatches a same-generation
successor through the shared attempt dispatcher. `retry_charge` is retained as
lineage/audit evidence, not an exhaustion budget; lost-attempt successors keep
retrying until one is durably dispatched.

`run_forever` wakes at `daemon.fast_poll_sec` (default 1s) for a cheap
probe: non-blocking child reap plus mtime stats of state files and stage
directories seen on the last full status scan. A child exit or mtime
change triggers a full `tick` immediately; otherwise
`daemon.poll_interval_sec` (default 30s) remains the backstop full-scan
cadence for changes the cheap probe cannot see.

On graceful shutdown, the supervisor snapshots each ancillary child's verified
descendant tree and original process group before sending TERM, then escalates
survivors to KILL. It returns a reaped direct-child exit only after the captured
tree and group are both proven gone. `Dispatcher#record_completed` routes those
safe exits through the normal controller, patrol, architecture-patrol, digest,
and request completion lifecycle before closing. A terminated architecture
scan therefore releases its existing generation-fenced v2 claim with ordinary
retry backoff instead of remaining `analyzing` until the two-hour lease
expires. If tree identity cannot be verified or any captured process survives,
the exit is withheld and its claim remains fenced for the existing lease
recovery path rather than permitting overlapping generations. Signal-derived
nil exits are failures for terminal recovery and ordinary patrol; only an
explicit success exit clears failure state.

Each full tick first publishes a `started` record, then reconciles durable
attempts, processes normalized loss, and publishes lease-first capacity. It
then runs: reap ancillary children -> enforce child
timeouts -> prune dispatch-result notices -> **tick the digest scheduler** ->
fetch status -> backfill missing meta ids -> observe every task-bound PR in
stages 5–8 -> advance one persisted merge candidate per project -> run
repository-wide architecture catch-up -> heal stale ownership and cooled
durable errors -> backfill missing display names -> **process dispatch
requests** -> patrol dispatches -> per-row dispatch -> prune baselines ->
refresh cheap-probe mtime fingerprints. Merge reconciliation runs before
automatic recovery so a safely delivered task cannot launch another provider
attempt. Dependency/admission-held candidates stay persisted but ineligible;
they are never dropped and become eligible when a later observation clears
the hold.
Dispatch requests come BEFORE the row-scan so a slug whose request just
dispatched this tick is already in-flight in the controller and the row
scan's per-slug in-flight gate (`controller.running_task?`) keeps the same
tick from double-spawning.

Scheduler decisions are captured in memory as each row is evaluated. At the
end of the tick the dispatcher fetches status a second time and publishes a
`complete` snapshot only after matching task identity, generation, stage,
marker/attrs, attempt, state-file mtime, action, dependency/admission policy,
and blocked state across that source window. Added, removed, or policy-changed
rows receive an unavailable disposition instead of a stale decision. The
assembler rejects the entire tick as `duplicate_task_identity` when either
source frame still contains multiple physical rows for one project/slug, so a
provider hold or dispatch decision from one row cannot be attached to another.
The status-side join rechecks the same fields, so a decision cannot remain
authoritative after a change between the completed daemon tick and a later
status read. The record also carries daemon generation/PID/start identity,
sequence and validity window, capacity, queue counters, provider holds,
coordinator recovery receipts, and per-task owner/reason.
Retry dispositions additionally carry the exact marker-age `retry_at`,
whether the boundary is due, the current safety verdict, and its reason.
`retry_cooldown` is scheduler-owned, `retry_in_flight` is agent-owned, and
`retry_safety_blocked` is operator-owned (or Hive-owned when inspection itself
failed). Failed reconciliation/status
or failed revalidation publishes `failed`. Snapshot age starts at the actual
completion sample rather than the tick-start sample, and a SIGHUP poll-interval
reload immediately reconfigures the assembler's next validity window.

SIGHUP reads and validates the daemon, update, digest, and answer-digest
blocks into locals before replacing live policy or the healer. A failure in
even the last loader therefore preserves the previous retry switch and every
other live config block together; both enable-to-disable and disable-to-enable
failures remain coherent.

Durable admission results retain their real scheduler meaning in this record:
only an accepted attempt is `dispatched`; an already-live attempt is
`in_flight`, while capacity deferral, terminal replay, lost attempts, invalid
predecessors, and launch handoff failures keep distinct owner/reason evidence.
Recovery retries do not exhaust. A terminal coordinator receipt remains visible
only while no fresh recoverable marker has replaced the completed generation.

Operational task capacity uses the same accounting as dispatch admission:
task-kind internal runs plus reconciled external task runs. Patrol scans and
the global digest remain visible in the diagnostic `running` list but do not
consume the global/per-project task slots or create phantom capacity projects;
both have separate scheduler budgets.

The reader treats incomplete phases, a stopped/replaced daemon, generation
mismatch, expiry, malformed content, unsafe symlink/hard-link/permissions, and
unreadable paths as typed non-authoritative evidence. Snapshot publication is
advisory: write/assembly failure logs `operational_snapshot_publish_failed` but
does not stop dispatch. Consumers therefore report partial/unknown status
rather than either crashing Hive or presenting old scheduler state as current.

Durable task admissions use `Attempts::API`; its internal daemon adapter
resolves the task and reloads that project's attempt heartbeat, stale, launch,
and first-heartbeat timers for every initial or loss-successor dispatch. A
daemon crash between queue preclaim and attempt-ID stamping is repaired on
restart by looking up the immutable attempt `request_id`; the repaired claim is
persisted before normal live/terminal/lost delivery reconciliation continues.

On Linux the shipped systemd-user unit uses `KillMode=process`. Service
restart therefore replaces only the daemon process; detached durable-attempt
wrappers and workers remain alive for the first reconciliation pass to adopt,
rather than being killed as cgroup children and replayed.

The answer-digest scheduler dispatches before status fetch because it is global,
not project-row driven. The dispatcher tracks its synthetic project/stage and
advances the cursor only on exit 0. The dry-run pseudo-child path uses the same
completion hook. Scheduler `tick` and `complete` calls are isolated so state I/O
failures log `fatal` with `keeping_previous: true` instead of crashing the poll
loop.

Architecture-patrol dispatches are ordinary supervised child processes but
not ordinary task rows. Discovery and action claims bind owner, exact process
start identity, process group, renewable heartbeat/lease, and fencing
generation. Workers do not claim without a verifiable start identity; recovery
can resolve a definitely dead PID but fails closed for a live process whose
identity cannot be proven. A replacement generation is allowed only after the
expired owner is proven gone or its process group is terminated. The scheduler
takes one immutable ownership snapshot per candidate-selection pass, sharing
registration/config/identity/continuation reads (and failures) across every due
job in that tick. Reservation deliberately ignores that snapshot and resolves
the live inputs again. Full authority requires the target's exact registered
name/path. Live identities from architecture-enabled registrations count even
when their daemon is disabled, while every registered project ledger is
scanned for nonterminal remote intents, PR/issue URLs, or review-handoff paths;
those pending continuations remain owners even after that registration is
disabled. Missing registration, duplicate owners, and unreadable
config/identity/continuation state fail closed. Feature checkpoints and action
receipts live in the authoritative job aggregate, so daemon restart
reconstructs work rather than trusting its in-memory slots. Action children
resume classified/acting jobs separately from read-only discovery and re-check
current consent and unique ownership before each new external effect, plus
ownership and the current action claim before a PR handoff. Large v2
documents are written atomically under
`.hive-state/refactor_patrol/v2/results/`; the supervisor consumes and removes
the exact path carried in the dispatch token when the child is reaped.

Architecture-patrol state/checkpoint/result writers use the shared
`Hive::AtomicFile.fsync_directory` policy after rename/unlink boundaries. The
helper performs a real directory fsync where Ruby/the filesystem supports it
and consistently treats `NotImplementedError`, `EINVAL`, `ENOTSUP`, and `EBADF`
as best-effort unsupported-platform cases.

Project config failures are visible lifecycle state rather than an omitted
candidate. During candidate enumeration the scheduler records
`project_config_unavailable` against every due discovery/action job it can find
for the affected registration. Reservation reloads config after candidate
selection; if that second read fails, it records the same durable block before
raising `ReservationBlocked`. This closes the candidate-to-reservation config
race without dispatching under a stale snapshot.

Merge catch-up stores
`.hive-state/refactor_patrol/v2/reconciler.json` as
`hive-refactor-patrol-reconciler` v2. The checkpoint carries registration,
exact host, canonical repository, default branch, high water, overlap
occurrences, and timestamps. Corrupt/unsupported checkpoints and later
registration, host, repository, or default-branch changes are quarantined and
block intake instead of creating a new baseline over the old identity.

Catch-up no longer has to traverse every GitHub page and hydrate every manifest
inside one daemon call. `RefactorPatrolMergeReconciler` applies one monotonic
tick deadline (15 seconds by default), gives each project a fair slice of the
remaining time, and caps an individual page or manifest-hydration operation at
5 seconds by default. Partial projects rotate between rounds, and the registry
starting position rotates between ticks, so a slow or failing first project
does not starve later registrations. A partial/deferred result schedules prompt
continuation rather than waiting for the ordinary poll interval.

The task-bound reconciler runs before repository-wide catch-up and gives every
project at most one candidate turn per full tick. Its GitHub call retains an
explicit timeout. Once merge facts are checkpointed, the architecture
reconciler performs exact-PR intake under its bounded shared deadline; an
accepted receipt is checkpointed before archive, while deferral or failure
parks only that candidate. Catch-up then runs with the remaining budget. A
slow repository therefore cannot consume another project's turn or erase its
backlog.

Incremental state lives in the separate
`.hive-state/refactor_patrol/v2/reconciler-progress.json` v1 sidecar. The
sidecar binds registration, host, repository, and default branch to a SHA-256
fingerprint of the unchanged v2 checkpoint. Its scan section stores the fixed
overlap start and upper time bound, the first page's frozen result count,
pagination cursor and seen cursors, accumulated PR identities, then the
manifest-intake index and already-enqueued PR numbers. GitHub search uses stable
creation order and one exact ISO timestamp range qualifier inside that fixed
merge-time window. This keeps GitHub's result count and the terminal traversal
bound to the same second-level interval. If GitHub indexing changes the count
or terminal traversal size between pages, the scan restarts from page one while
retaining the original upper bound, so first-enable cannot absorb a new merge
into its baseline. Every completed page and intake step is written atomically
before the next step. A daemon restart therefore resumes the next page or item;
if a crash occurred after a write-once job was enqueued but before the sidecar
advanced, replay converges through idempotent intake.

The project slice begins before origin identity discovery: the local `git`
remote lookup, authentication, page fetch, and exact-PR metadata/file hydration
all receive only the remaining portion of the same monotonic deadline. Spending
the slice during identity discovery defers before a second remote operation.

Remote failures persist `failures`, `not_before`, and a bounded `last_error` in
the same sidecar. The exponential delay ceiling starts at 5 seconds, is capped
at 300 seconds, and is jittered; a restarted daemon honors `not_before` without
calling GitHub. Progress writes and the final v2 checkpoint use atomic
tempfile/fsync/rename plus directory fsync. Completion writes the checkpoint
first, then unlinks and directory-fsyncs the sidecar. If a crash leaves that
old sidecar behind, its base-checkpoint fingerprint no longer matches and the
next tick removes it instead of replaying stale work. Corrupt or identity-drifted
progress is preserved under `quarantine/reconciler-progress/` and blocks rather
than being silently trusted. Timestamp/scalar/OID types and cursor state are
strict: an already-consumed current cursor is quarantined as impossible local
continuation state, while a cursor loop returned by a live GitHub page follows
remote failure/backoff. Dry-run uses only an in-memory sidecar and JSON-detaches
both writes and reads so its mutation semantics match disk-backed JSON loads.

`Hive::Daemon::Policy` and `Hive::Daemon::ConcurrencyController` have no
I/O at all — fully unit-testable without forking. The other modules
each expose a thin enough seam that mock collaborators (see
`test/unit/daemon/dispatcher_test.rb`) cover the routing behaviour
without spinning up the whole stack.

Policy's advance-action set includes the descriptor-generic
`ready_to_advance` and `ready_to_run` actions. `ready_to_advance` emits
`hive approve <slug> --from <descriptor-stage-dir>` for non-terminal generic
`COMPLETE` rows and inert markerless entry stages; `ready_to_run` emits
`hive run <slug>` for markerless generic agent-style rows. Policy treats both
like the existing coding `ready_to_*` actions: non-empty command plus clear
admission returns `:dispatch`; an admission error returns `:admission_error`,
and an ordinary dependency wait returns `:blocked_on_dependency`. Both holds
also suspend the durable merge candidate without deleting it. The dispatcher logs admission
`reason_code`, `offending_ref`, and `safe_correction` separately from benign
wait context and never spawns for either hold. The coding
`3-plan` `needs_input` auto-approval shortcut is now gated on
`workflow == "coding"` (nil workflow remains coding for old test doubles), so a
generic stage whose dir happens to be `3-plan` uses the normal edit/mtime path.

## Trust boundary

The daemon adds NO new forward-advance approval logic. Workflow-verb
safety is delegated to `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`
(`%i[complete execute_complete review_complete]`). The daemon is a
subprocess caller; it never `File.rename`s task folders or touches
per-task `.lock` files directly. Any misclassification at the `Policy`
level surfaces as `Hive::WrongStage` (exit 4) at the workflow-verb
level, not as a silent advance past a human gate. Spawned workflow verbs also
revalidate dependency admission under their task/commit locks, closing the
status-to-child race. See ADR-024 and [[modules/task_dependencies]].

The daemon has two narrowly-scoped marker-transition authorities. Neither
advances a workflow stage directly:

1. **`Hive::Daemon::PlanApproval`** flips a plan-stage `:waiting`
   marker to `:complete` to satisfy the `hive develop` terminal-
   marker gate when the per-project consent (`daemon.enabled: true`)
   is the durable approval signal. Validates the dispatch command's
   shape before flipping (`Hive::Daemon::PlanApproval.prepare`).
2. **`Hive::Daemon::StaleAgentHealer`** rewrites stale `AGENT_WORKING`
   markers to `ERROR reason=agent_died` (dead `claude_pid`) or
   `ERROR reason=agent_orphaned` (placeholder marker stamped at
   stage entry that no agent ever attached to, older than
   `daemon.agent_marker_grace_sec`, default 300s). Skips rows whose
   project has a half-migrated layout (`legacy_stage_dirs`) and rows
   for which the `ConcurrencyController` has a live in-flight slot, or
   rows where `StatusConsumer` reports `live_task_lock: true` because an
   external `hive run` still holds a verified task lock. The exception is
   `REVIEW_WORKING`: if the row's `claude_pid_alive` is false, the current
   lock PID/start-time/lock-id still match the identity captured by status,
   and `pgrep -P <holder>` proves the holder has no children, the healer treats
   the parent as wedged. It terminates only that process identity, claims a new
   task-lock generation, and rewrites the matching occurrence to
   `REVIEW_ERROR`. A replacement holder or failed claim leaves the marker
   untouched. If child inspection fails, or children still exist, it leaves
   the row alone.

   Every `ERROR` and `REVIEW_ERROR` is a durable retry state, never a permanent
   workflow terminal. Every reason—including lost sessions,
   `unpushed_commits`, reviewer crashes, `agent_preflight_failed`,
   tampering/integrity classifications, dirty-worktree failures, unknown
   failures, and timeouts—re-enters after the same shared marker-age
   cooldown. The daemon cannot infer whether files,
   configuration, credentials, provider state, or the configured agent binary
   changed, so the rerun itself is the universal health probe. A repeated
   failure writes a fresh marker and restarts the cooldown; no error retry
   budget can exhaust.

   `StaleAgentHealer` is only the automatic scheduler for those durable errors.
   After the shared marker-age cooldown it submits the observed row to
   `RecoveryCoordinator`; it never clears a recoverable marker itself and has
   no retry counters, exhaustion budget, or stage-specific requeue branch.
   TUI, Rails, Telegram, recorder, and CLI/action adapters submit the same
   observation through `Hive::Recovery::API`.

   `RecoveryCoordinator` is the sole destructive owner. Under the task lock it
   re-resolves the canonical task, requires the same `marker_id`, rechecks
   ownership and work-area safety, persists one generation-bound v4 request,
   then resumes the crash-safe
   `admitted → cleared → dispatched → terminal` lifecycle. An old id-less
   marker fails with `recovery_migration_required` and must be upgraded once
   with `hive migrate`; there is no mtime/reason identity fallback. Workflow
   retry argv are derived centrally, including `3-plan`, so clearing can never
   become an alternate scheduling mechanism. Queue admission, capacity,
   cooldown, and quarantine gates still apply. A post-clear launch failure
   returns the durable request to scheduler ownership with the same shared
   cooldown instead of creating a per-tick loop.

   **Usage/credit limits self-heal through
   periodic readiness attempts:** any `limits_reached` marker — review `REVIEW_ERROR`
   markers written by `Stages::Review` when all reviewers, triage, or fix hit
   provider usage/credit limits, and the
   single-agent `ERROR reason=limits_reached` written by `ClaudeLauncher` /
   `Agent` (any stage, since a limit can hit brainstorm/plan/execute too) —
   carries a `retry_after` ISO8601 stamp set at write time. A complete dated
   provider hint is used with a one-minute grace; otherwise the stamp is
   `now + cooldown` (`Hive::AgentLimit::RETRY_COOLDOWN_SEC`, default 3600s =
   1h, overridable per-process via `HIVE_LIMITS_RETRY_COOLDOWN_SEC`). That
   stamp is display-only. The healer schedules from the quota marker's mtime
   and submits it once one cooldown interval has elapsed, even when the provider
   advertises a later reset or the stamp is missing/malformed. A repeated wall
   writes a fresh marker and therefore starts the next interval; successful
   usage resets, top-ups, or account switches stop producing the marker. These
   readiness attempts use the same unbounded policy as every other error.
   Logs retain `reason=limits_reached` / `reason=reviewer_limits_reached` as
   diagnostic labels, while durable request history supplies the retry count.

   Recovering an error reruns the owning stage through its normal checks;
   it does not bypass tamper detection, clean-exit scope, branch identity,
   repository status, authentication, or publication guards. Tamper reasons
   require `restored=true`; controller-owned bytes and forged sentinels are
   restored immediately after the spawn. Worktree-bearing stages require the
   exact task path/slug branch to remain registered in the same repository.
   At `4-execute`, an owned dirty worktree is durable failed-attempt progress,
   not a retry blocker: the rerun resumes it in place and the execute runner
   still refuses completion until branch, ancestry, cleanliness, and commit
   checks pass. A missing, tampered, or differently owned pointer still blocks.
   Secret errors remain parked while the local source still matches a
   credential, and PR stages scan current remote content before publication.
   If GitHub later reports a task-bound PR as `MERGED`,
   `PrMergeWatcher` may close the task from any PR-bearing coding stage
   through `Hive::TaskClosure.reconcile_remote_merge!`. The daemon writes a
   `channel=daemon`, `authority=remote_merge` receipt only after repository,
   head, merge reachability, generation, live-owner, worktree, and required
   architecture-intake checks pass. The same centralized transition moves the
   task to `9-done`; no archive subprocess or special marker-reason bypass
   remains. Coordinator
   submissions log `recovery_requested` / `recovery_blocked`; stale ownership
   rewrites retain `marker_healed` / `marker_heal_failed`.

## External liveness and capacity

`Hive::Commands::Status` emits `tasks[].live_task_lock` when a task
`.lock` holder PID is alive and its recorded process start time still
matches. `StatusConsumer` carries that boolean into each row. The
dispatcher then treats `agent_running` rows as externally active only
when there is positive liveness evidence: either `claude_pid_alive ==
true` or `live_task_lock == true`.

That predicate feeds both the global external-active count and the
per-project active count used by `ConcurrencyController`. A row whose
only liveness signal is `live_task_lock` consumes daemon capacity, so a
daemon restart during auto-rebase cannot dispatch extra work past the
configured caps. Rows with no live Claude PID and no live task lock do
not consume capacity; if they are stale `AGENT_WORKING` rows, the healer
will rewrite them on the same tick or a later retry.

`3-plan`/`needs_input` is the policy exception to the generic
edit-resume debounce. A generated plan in `WAITING` is an approval
pause, not a Q&A file waiting for typed answers. For daemon-enabled
projects the durable approval gesture is `daemon.enabled: true`, so the
policy dispatches the row's `hive develop ... --from 3-plan` command
immediately. Brainstorm, execute, and review `needs_input` rows still
use mtime-baseline + debounce because those states represent actual
user-authored answers or review decisions.

## Brainstorm answers-pending gate

mtime-debounce assumes a single edit gesture (one editor save). A
multi-question brainstorm Q&A answered over Telegram is **N separate
writes** — `Hive::Bot::DispatchRequestWriter`/the answer writer appends
each answer to `brainstorm.md` one at a time, bumping the mtime each
time. Without a guard, the daemon's edit-resume would fire ~`edit_debounce_sec`
after the **first** answer and re-run `hive brainstorm` with a partially
answered file (and grab the task `.lock`, bouncing the operator's next
answer with "Try again — another run holds the lock").

The fix gates the resume on whether any questions are still unanswered:

- `Dispatcher#brainstorm_answers_pending?(row)` parses the brainstorm
  file (via the shared `Hive::BrainstormParser`, relocated out of
  `Hive::Bot::` for exactly this reason) for a `2-brainstorm`
  `needs_input` row and returns true while any `### Q{n}.` lacks an
  answer. It returns false for every non-brainstorm edit-resume row
  (execute/review carry no Q&A markers). **Fails open** (resume) on a
  file that parses to ZERO questions or on an unexpected error — and
  this is self-healing, not a gap: the Telegram bot locates questions
  with the *same* parser, so a file with no parseable `### Q{n}.` (empty,
  agent crashed mid-write, header drift) is one the operator can't answer
  via the bot either; the recovery is to re-run the brainstorm agent,
  which regenerates a clean file, and holding would strand it instead.
  `parse` is hardened (encoding-scrub + IO-resilient) so a torn
  concurrent read — the bot appends an answer while the daemon parses —
  degrades rather than raises; the residual `:fatal` rescue is deduped
  per `[project, slug]` so a persistently unreadable file can't spam the
  log every tick.
- `Policy.decide` takes `answers_pending:` and downgrades a would-be
  `:dispatch` to `:wait_for_answers` — but **only** the terminal
  dispatch. The first-sight `:record_baseline`, `:skip`, and
  `:wait_for_debounce` outcomes pass through unchanged, so the mtime
  baseline is still seeded and the **editor-bulk-save** path (all answers
  in one save → no unanswered slots) resumes normally.
- The dispatcher logs the hold as `:skipped reason=answers_pending`, and
  `hive status --json` carries an `unanswered_questions` count for the
  row (issue #270) so the hold is observable without tailing the log —
  see [[commands/status]]. A held brainstorm whose question has no
  fillable `### A` slot is no longer a dead-end: `BrainstormAnswerWriter`
  now creates the slot on answer (issue #269), so the operator can always
  clear the hold (see [[modules/bot]]).

This is surface-agnostic: it holds whether answers arrive incrementally
via the bot or all at once via a direct edit. The bot's own "all
answered → enqueue a dispatch request" path then just races the row-scan
to the same gate; the per-slug in-flight gate dedups.

## Persisted dispatch baselines (restart survival)

The mtime baseline above is the `[project, slug] → state_file_mtime`
value `Policy#decide_edit` compares against on first sight of an
edit-resume row. It lives in `ConcurrencyController#@last_dispatched_mtime`,
which is otherwise in-memory only — so before this was persisted, any
daemon restart re-recorded the baseline at the *current* mtime and a
user answer written *before* the restart stopped looking "newer than
baseline", stranding the task on every tick until the operator manually
`touch`ed the state file. The same stranding hit bot-dispatched
brainstorms the daemon never recorded a baseline for.

`Hive::Daemon::DispatchBaselines` (`lib/hive/daemon/dispatch_baselines.rb`)
persists that map to `daemon_dispatch_baselines.json` under
`Hive::Paths.state_home` (beside `.daemon.pid`), mirroring
`Hive::UpdateCheck::State`'s discipline: a JSON envelope with
`schema_version`, atomic write (tempfile + fsync + rename + dir fsync)
behind a sibling `.lock`, and a **fail-closed** load — a torn / partial /
corrupt / newer-schema file degrades to an empty map and the daemon boots
normally (worst case: one task is re-baselined once). The controller
write-throughs on every baseline mutation — first-sight record, dispatch,
terminal-attempt replay, post-completion refresh, AND prune — so there is no
batched loss window for the critical value. A terminal replay means the
durable attempts layer already completed that exact task generation; recording
the observed state-file mtime prevents the unchanged waiting marker from being
readmitted on every daemon tick, while a later edit still becomes eligible.
Mtimes are stored at microsecond resolution and
`hive status --json` emits task `mtime` / `folder_mtime` with matching
microsecond precision. Do not truncate status JSON mtimes: an operator
answer can land in the same wall-clock second as the daemon baseline, and
whole-second JSON makes the newer answer compare as older or equal. The
comparison stays mtime-to-mtime, never wall-clock — no clock-skew
class of bug, the reason the earlier marker-`ts` approach was rejected
(see PR #229). The dispatcher prunes entries absent from the live status
rows once per **successful** tick, **scoped to the projects in
`result.projects`** — never on a failed/empty fetch, AND never wiping a
project that hit a per-project `error: not_initialised` /
`missing_project_path` and is absent from this tick's snapshot.
Same-host only.

**Failure-mode visibility:** the store is constructed with the daemon
logger so every persistence path is observable in `daemon.log`.
`:daemon_dispatch_baselines_loaded` (count + `suspend_writes`) fires on
every load so the operator has a positive boot-time signal that
persistence is in use. Torn / wrong-shape files emit
`:daemon_dispatch_baselines_corrupt`; a newer-schema file (downgrade
protection — writes suspended) emits
`:daemon_dispatch_baselines_newer_schema_suspended`; lock acquisition
failures emit `:daemon_dispatch_baselines_lock_error`; write errors
(ENOSPC / EROFS / EDQUOT) emit `:daemon_dispatch_baselines_write_error`;
orphan-tmp sweep failures emit
`:daemon_dispatch_baselines_tmp_sweep_error`; and the store's
defense-in-depth `rescue StandardError` around `write` emits
`:daemon_dispatch_baselines_unexpected_error` if a programmer-error class
slips past the narrower I/O rescues. None of these crash a tick; all
appear in `daemon.log` so a silent re-strand cannot happen unobserved.

`ConcurrencyController#prune_dispatch_baselines` requires
`scope_projects:` — there is no nil-default. Forgetting the kwarg now
fails loud at the call site rather than silently re-stranding answered
tasks across per-project status errors.

**Accepted limitation:** if the daemon is down for the *entire* window
between a bot-dispatched brainstorm's `WAITING` write and the user's
answer, no baseline was ever recorded, so the answer becomes the baseline
on first start and the task waits for the next edit. The daemon is
normally up, so the window is tiny; the operator can re-save / `touch`.

## Single-dispatcher: producers write requests, daemon dispatches

The original queue-only single-dispatcher design below explains why producers
stopped spawning competing task children. Current task execution goes one step
further: queue consumption, CLI calls, auto-advance, and recovery all resolve
through `Attempts::Dispatcher`. The claim records the attempt ID/generation;
the detached wrapper receipt completes delivery. The daemon never registers
that task wrapper in `ChildSupervisor`. Current writers emit request v4;
runtime readers accept v4 only after the one-off queue migration. See
[[modules/attempts]].

Before plan 2026-05-28-002, both the daemon AND the Telegram bot
could spawn `hive run`-class verbs. The daemon tracked an in-memory
`last_dispatched_mtime` baseline per `(project, slug)` and refreshed
it on every reap — but only on reaps of children IT spawned. The
bot's `hive run` child was reaped by the bot's `ChildSupervisor`,
so the daemon never saw the post-completion mtime bump from the
agent's own write. On the next tick the row's mtime exceeded the
stale baseline; Policy returned `:dispatch`; the daemon spawned a
redundant runner that held the per-task lock for 1-2 min, during
which the bot rejected legitimate user answers with "Try again —
another run holds the lock".

The fix collapses the two dispatchers into one. The bot and hivebox web are
producer-only for state-mutating stage runs: they write JSON request files via
`Hive::Bot::DispatchRequestWriter.write!` into
`<state_home>/dispatch_requests/`. Recovery adapters reuse the queue through
`RecoveryCoordinator`; no adapter writes a clear-and-run sequence.
The daemon tick consumes `DispatchRequestQueue.pending`, validates the argv
allowlist, and resolves task verbs through durable admission. Request IDs stay
on the delivery while attempt IDs own execution; receipt reconciliation
unlinks the claim and logs completion.

Current request schema is v4. It carries generation intent, predecessor
attempt, inherited output references, and a restartable recovery object with
canonical task, stage, marker ID, expected attrs, dispatch generation,
owner/remediation, phase, retry count, and terminal outcome/time. The one-off
recovery migration upgrades pending v1-v3 deliveries before the runtime queue
opens; queue readers accept v4 only and contain no inferred-generation
compatibility path. Identity-bound recovery requests do not expire; the
consumer rejects them if the task, stage, post-clear generation, or marker
history no longer matches.

The dispatcher materializes pending and claimed rows once per tick and reuses
that immutable queue state for both operational counters and recovery
receipts. A `retry_pending` projection is `queued` only when a matching
canonical request has a request ID; malformed or absent queue evidence leaves
the ordinary retry action available instead of inventing a request. Terminal
recovery receipts remain durable for history, while filesystem pruning is
throttled to one pass per hour so a five-second dispatcher loop does not
rescan and rewrite retention state continuously.

```
:dispatch_request_observed   request_id=… project=… slug=…
:dispatch_request_dispatched pid=… command=…   (only when dispatched)
:dispatch_request_blocked    reason=admission_error|dependency_unmet|in_flight|cooldown|…
:dispatch_request_completed  pid=… exit_code=… elapsed_sec=…
:dispatch_request_rejected   reason=invalid_argv|unknown_project|…
:dispatch_request_expired    created_at=…
:dispatch_request_recovered  reason=owner_gone|claim_expired|malformed_claim  (startup claim sweep, C3)
:dispatch_result_written     exit_code=… chat_id=…  (bot-originated completion → bot relay, ADV-1)
```

Lifecycle gates inside `process_dispatch_requests`:

1. Allowlist (`valid_argv?`) — invalid → reject + remove.
2. Expiry (`DispatchRequestQueue::EXPIRY_SEC` = 600s) — old → expire + remove.
3. `find_project` lookup — unknown → reject + remove.
4. For every project-scoped verb except `markers`, locate the same tick's
   status row; `admission_error` or `blocked: true` → blocked, file stays.
5. `controller.running_task?` — already in flight for this slug →
   blocked, file stays for the next tick.
6. `controller.can_dispatch?` gate (caps / cooldown / quarantine) —
   blocked → file stays for the next tick.
7. Otherwise → preclaim the delivery and resolve task-stage work through
   durable attempt admission. Capacity/loss deferral returns the claim to
   pending; accepted/live/receipt outcomes retain an attempt reference until
   terminal delivery. Marker repair and global daemon maintenance continue
   through the ancillary child-supervisor path.

For a recovery request already in `cleared`, a launch/preflight deferral first
persists a new `next_eligible_at` through `RecoveryCoordinator`, then releases
the claim. The same durable request is therefore retried on the universal
cooldown instead of being re-admitted on every daemon tick.

Lease reconciliation refreshes capacity and completion before another
admission. A different request ID for the same live task generation resolves
to the existing owner rather than another spawn.

An internal worker or ancillary child that returns an `admission_error` JSON
envelope with CONFIG exit 78 represents task-local validation state; delivery
or reap does not mark the whole project dropped, so unrelated rows remain
schedulable.

Patrol and refactor-patrol CONFIG exits are likewise job-local. Missing patrol
validation commands enter scheduler backoff without marking the registered
project dropped, so ordinary task stages continue to dispatch. The concurrency
controller frees patrol capacity without applying per-task CONFIG/drop state;
the patrol scheduler is the sole owner of scan backoff. Patrol scans also run
outside the ordinary per-project daily task quota.

`reap_completed` always refreshes the controller's
`last_dispatched_mtime` baseline (no longer just for daemon-spawned
children — the bot doesn't spawn them anymore). The bug dissolves:
the same code that observes the mtime is the only producer of the
spawn.

See [[architecture]] §"Dispatch flow" for the cross-layer picture.

### At-most-once dispatch via atomic claim (C3)

A pending request file used to stay as `<id>.json` from spawn until
reap. A daemon crash in that window re-dispatched the request on
restart — re-running work that may already have completed. The fix
(`DispatchRequestQueue.claim`) renames the file to
`<id>.json.claimed` before the daemon admits work. The claimed JSON
stays schema-valid for the dispatch-request version the producer wrote
(current writers emit `hive-dispatch-request.v4`); mutable claim metadata
(`pid`, `process_start_time`, `claimed_at`, `attempt_id`, `task_generation`) lives in a sibling
`<id>.json.claimed.claim` sidecar that is updated after spawn. Claimed
files are invisible to `pending` (the glob matches `*.json`, not
`*.json.claimed`), so a later tick never re-observes them — **each
queued request is dispatched at most once, ever**. The claimed file,
claim sidecar, and any sequence sidecar are unlinked after receipt delivery.

`claim` uses a single rename of `<id>.json` to `<id>.json.claimed`, but
a crash or filesystem race can still leave a stale original beside a
claimed file. Two guards close the resulting double-dispatch hole:
`pending` skips any `<id>.json` whose request_id already has a
`.claimed` sibling (so a lingering original is never re-observed), and
`recover_claims` removes the orphan `<id>.json` alongside the `.claimed`
it sweeps.

At startup, `Dispatcher#recover_dispatch_claims` sweeps claim files
left by a prior process via `DispatchRequestQueue.recover_claims`:

- **owner still alive** (pid alive AND, when both `process_start_time`s
  are present, they match) → the file is left alone; the daemon cannot
  reap a process it did not spawn, so a later restart cleans it once the
  orphan dies.
- **owner gone / PID reused** → removed WITHOUT re-dispatch; if the run
  died mid-flight the task's own marker drives recovery through the
  normal status→alert path.
- **claim aged past the claim-expiry window** → removed regardless, so a
  wedged alive child can't pin a claim forever. The window is `CLAIM_EXPIRY_SEC`
  (a generous default), overridden per-restart by the dispatcher to
  `child_timeout_sec + child_kill_grace_sec + 2·poll + margin` — sized to
  the run budget, NOT the 600s `EXPIRY_SEC` unclaimed-request window
  (which would age out a live ~90-min run 10 minutes into a restart).

Each removal logs `:dispatch_request_recovered request_id=… reason=owner_gone|claim_expired|malformed_claim`.

**Crash-durability (#248).** `claim` fsyncs the `dispatch_requests/`
directory after the `.claimed` rename and sidecar write, so the
at-most-once commit point survives an unclean shutdown rather than
silently un-persisting and re-dispatching on restart. The directory
fsync is best-effort (swallowed on platforms that won't open a
directory for fsync) so it never aborts the claim it hardens.

**Still-alive orphan window (#264).** When `recover_dispatch_claims`
keeps a still-alive orphan's claim (correct — the restarted daemon
can't reap a process it didn't spawn), it does **not** re-register that
`(project, slug)` in the fresh `ConcurrencyController`. For the interval
until the orphan exits (or its claim ages out), the per-row auto-advance
path — gated only by the now-empty `running_task?` — could dispatch an
advance for the same slug. The task `.lock` is the backstop that still
prevents two live runs of the same task; it is a narrower guarantee than
an in-flight controller slot but holds across the restart. Re-registering
the orphan was deliberately rejected: with no supervised child to reap,
the slot would only free on claim age-out (up to `CLAIM_EXPIRY_SEC`),
trading a narrow already-backstopped window for a guaranteed multi-hour
stuck slot.

**Prune is claim-safe (#265).** `hive daemon queue prune` runs in a
separate CLI process with no lock. A request can be claimed+dispatched by
the daemon between prune's `pending` scan and its removal; prune uses
`remove_if_unclaimed`, which re-checks the claimed set and removes only
the pending `*.json` (never a `*.json.claimed`'s crash-recovery state),
counting only files actually unlinked. Reported prune counts are
therefore advisory under concurrency but never delete a live claim or
over-report a removal a racing claim turned into a no-op.

`ChildSupervisor#pgid_for` returns **nil** (not the pid) on `ESRCH`
(#249), so the timeout-kill callers' `if pgid` guard short-circuits
rather than signaling `-pid` — which could hit a recycled process group
on a long-running host.

### Per-child wall-clock timeout (R-02)

`ChildSupervisor` enforces a per-child timeout for ancillary work so a wedged
command can't hold a concurrency slot until daemon shutdown. The timeout is
resolved AT SPAWN from the verb (`daemon.child_verb_timeouts[verb]`
falling back to `daemon.child_timeout_sec`, default `0` (disabled)) and
frozen on the running entry so a mid-run reload never
retroactively kills a live child. Each tick, `Dispatcher#enforce_child_timeouts`
calls `ChildSupervisor#enforce_timeouts`: a child past its deadline gets
SIGTERM, then SIGKILL after `daemon.child_kill_grace_sec` (default 30s),
each logged as `:child_timeout action=term|kill elapsed_sec=… timeout_sec=…`.
The killed child surfaces as a normal `ChildExit` on a later reap. See
[[config]] for the knobs. The in-code `fetch` fallbacks for
`child_timeout_sec` reference `Hive::Config::DEFAULTS.dig("daemon",
"child_timeout_sec")` rather than a hardcoded literal, so an un-merged
daemon block can never silently drift from the canonical default (#255).

Task-stage commands now resolve the same verb timeout and
`child_kill_grace_sec` when their detached durable wrapper is created. The
long-lived `Attempts::API` delegates daemon admissions to an internal configured
adapter that reloads the task project for lease timers and the global daemon
block for verb timeout, kill grace, and global, per-project, and daily admission
caps on every initial attempt and loss successor. A global config change
therefore affects the next admission without replacing the daemon, while each
already-running wrapper keeps its frozen launch policy.
After a worker leader exits, its supervisor
continues heartbeats and the monotonic timeout while draining inherited output
pipes. Heartbeats also continue during the TERM-to-KILL grace; the supervisor
TERM/KILLs the recorded group and closes a pipe that outlives that grace instead
of waiting forever for EOF.

A lost record whose worker group has not been proven absent or terminated
continues to reserve global, project, and task capacity. Missing/corrupt cleanup
evidence and manual `still_alive`/identity-unsafe outcomes fail closed; capacity
is released only after the durable cleanup outcome records `absent`,
`terminated`, or `no_worker`.

`child_kill_grace_sec` is a **minimum, not a precise timer** (#266):
`enforce_timeouts` runs once per `poll_interval_sec` tick (default 30s),
so the actual SIGKILL can arrive up to one poll interval after the grace
window nominally elapses, and `child_kill_grace_sec: 0` does NOT mean
immediate KILL — it means "KILL on the next tick after the TERM".
Operators tuning the grace for a hard real-time bound should account for
the poll interval. Detached attempt supervisors use their own monotonic loop,
so their escalation does not add the daemon poll interval.

### Queue sequence continuations

Legacy non-recovery callers may still express a multi-command queue operation
with `<request_id>.sequence`: on successful reap (`exit_code == 0`),
`Dispatcher#promote_dispatch_sequence` writes the next request with the
original routing metadata; on non-zero or nil exit it discards the sidecar.
Recoverable marker flows do not use sequences. They persist one v4 recovery
request whose coordinator-owned phases are `admitted`, `cleared`, `dispatched`,
and `terminal`, so a crash cannot separate marker mutation from its only retry
continuation.

Malformed claimed deliveries are never deleted as if they completed. Startup
recovery moves the exact request bytes and claim metadata into the owner-private
`dispatch_requests/quarantine/` directory and writes a SHA-256 evidence
sidecar. Queue readers skip one malformed delivery without hiding healthy
receipts from the same scan.

### Completion feedback to Telegram (ADV-1)

Because the daemon (not the bot) now spawns request-driven children and
has no Telegram handle, the operator who tapped a button needs a
reverse-direction reply path for both failures and successful
completion. On request-driven completion, `reap_completed` reads the
request's `chat_id`/`update_id` (from the still-present claimed file,
before unlink) and writes a notice via
`Hive::Daemon::DispatchResultQueue` into
`<state_home>/dispatch_results/*.json` (logged
`:dispatch_result_written`). Successful intermediate sequence steps are
the exception: when `exit_code == 0` promotes another queued command
from the hidden sequence sidecar, the daemon suppresses the result
notice for that step. Durable recovery does not use sequence sidecars and
therefore has no intermediate marker-clear success to suppress.

The bot drains that directory each `reaper_loop` iteration
(`Supervisor#drain_dispatch_results`) and relays either a positive
command-specific confirmation for exit 0 or a `⚠️ <slug>: hive <verb>
failed (exit N | killed)` message for non-zero/nil exits. This is the
reverse-direction sibling of the dispatch-request queue; schema
`hive-dispatch-result` v1. The schema machine-checks `chat_id` as
**non-zero** (`not: {const: 0}`), not merely a positive integer (#258):
0 is the only id no Telegram chat ever has, while private chats are
positive and group/supergroup/channel chats are negative, so a `minimum:
1` would have wrongly rejected a valid group relay target.

Reliability contract on the consumer side: a notice is removed **only
after the relay is confirmed sent** — if Telegram is down it stays on
disk to retry next tick (never a silent drop). Notices older than
`DispatchResultQueue::EXPIRY_SEC` (1h) are dropped without relaying
(no stale-completion spam), and the daemon prunes them each tick
(`prune_dispatch_results`) so a down bot can't grow the dir without
bound. A reconnect backlog larger than `DISPATCH_RESULT_SEND_CAP`
relays the cap individually and collapses the tail into one
per-chat summary, so it can't flood Telegram.

## Self-reexec on source drift (ADR-031)

The daemon is a long-running Ruby process whose in-memory constants
(notably `Hive::Schemas::SCHEMA_VERSIONS`) freeze at load time, while
shelled-out `hive` subprocesses load fresh code on every invocation.
A `git pull` or gem upgrade that bumps a schema version between daemon
restarts produces a producer/consumer mismatch where `StatusConsumer`
rejects every envelope (historically: 8,946 `got 2, want 1` events
were logged between PR #78 on 2026-05-15 and the next restart on
2026-05-20).

At startup the dispatcher captures a SHA-256 fingerprint of `lib/hive.rb`
(the file holding `SCHEMA_VERSIONS`). On every **full** tick (the
`poll_interval_sec` ~30s cadence, not the `fast_poll_sec` ~1s cheap
probe) it rehashes the file and compares — gating the hash behind
`full_tick_due?` keeps the per-second idle path to cheap waitpid + stat
work (Unit 2). On mismatch it logs `version_drift` with the old
and new digests, sets `reexec_requested?`, and breaks the run loop.
`Hive::Commands::Daemon#start_daemon` then `Kernel#exec`-replaces the
process with a fresh `hive daemon start` invocation — same PID, fresh
code on both producer and consumer sides. `--detach` is omitted from
the re-exec argv because we are already the daemonized child; calling
`Process.daemon` a second time would fork off and orphan us.

Rate-limited to one re-exec per 60s as a defense against pathological
fingerprint flapping. Operators can disable the behavior entirely via
`HIVE_DAEMON_NO_AUTO_REEXEC=1` (useful for tests and short-lived
dev runs).

## Forward-tolerant schema-version skew

`StatusConsumer#validate_envelope!` enforces only the envelope SHAPE
(`schema == "hive-status"` and `ok == true`) as a hard error. The
`schema_version` is NOT validated there — it is classified by
`schema_skew(doc)` into `:match` / `:newer` / `:older` and handled
tolerantly, because the long-running daemon holds an in-memory
`SCHEMA_VERSIONS.fetch("hive-status")` that goes stale the moment the
`hive` gem is updated under it without a restart. The pre-fix code raised
`ArgumentError, "schema_version mismatch: got N, want M"` on any
inequality; that same brittleness hard-crashed the Telegram bot's
`/status` (`got 3, want 2`) after a schema bump until the bot was
restarted.

Behavior by skew (both `StatusConsumer` and `Hive::Bot::StatusWatcher`):

- **`:newer`** (payload version > process version — an updated binary):
  parse best-effort. `hive-status` envelopes are additive by contract
  (see [[commands/status]] and ADR-028 carve-out in [[decisions]]), so a
  newer payload is still readable. The consumer returns `ok: true` and
  carries a non-fatal `Result#warning`; the dispatcher logs it once per
  tick as `:status_warning` (a neutral name — the same channel also
  carries status-command stderr breadcrumbs, so it is intentionally not
  skew-specific)
  and keeps dispatching. If best-effort
  extraction (`extract_rows`/`extract_projects`) genuinely throws, it
  degrades to the actionable failure `hive status: envelope schema vN is
  newer than this process (vM); restart the hive daemon to pick up the new
  version (underlying error: <Class>: <msg>)` — the **underlying exception
  is preserved**, not swallowed, so a genuine extraction bug that merely
  coincides with a newer schema stays diagnosable instead of being
  relabeled "just restart" forever.
- **`:older`** (payload version < process version — a stale binary on
  PATH): not parsed as trustworthy. Returns `Result(ok: false)` with
  `… is older than this process (vM); update/reinstall the hive binary on
  PATH`.
- **`:match`**: unchanged happy path; no warning.

**Validation runs OUTSIDE the skew degrade (fix-forward on #416).**
`validate_envelope!` (shape + `ok==true`) is called before the
best-effort extraction block, and extraction is wrapped in its own
`begin/rescue`. So an envelope that is both `:newer` AND `ok=false`
surfaces its real `envelope ok=false: <reason>` message — never the skew
restart hint. Only a throw inside extraction degrades, and only when
`skew == :newer`; an equal/exact-version extraction throw re-raises to the
outer rescue and surfaces the raw `#{e.class}: …` line (a real bug, not a
skew).

The contract: a long-running consumer must NEVER crash a tick (or the
bot's `/status`) with a raw `ArgumentError` purely because a
`schema_version` was bumped without a restart. It either keeps working
(forward-compatible) or returns a clear "restart to pick up vN" message —
without ever masking the real `ok=false` reason or a genuine extraction
defect.

`Hive::Bot::Supervisor#diagnose_reply_for_child` consumes the sibling
`hive-status-diagnose` envelope but only checks `schema == ...` and never
`schema_version`, so it did NOT share this brittleness and was left as-is.

## Backlinks

- [[commands/daemon]]
- [[commands/status]]
- [[modules/task_action]]
- [[decisions]] (ADR-024)
- [[architecture]]
- [[cli]]
