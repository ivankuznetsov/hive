---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-07-20
tags: [daemon, module, automation, dispatcher, operational-status, snapshots]
---

**TLDR**: Small modules under `Hive::Daemon::*` that together form
the auto-advancing dispatcher (ADR-024). Pure logic (`Policy`,
`ConcurrencyController`) is separated from I/O (`StatusConsumer`,
`ChildSupervisor`, `Logger`, `PrMergeWatcher`, `DigestScheduler`,
`StaleAgentHealer`, `RecoverableErrorHealer`, `DisplayNameBackfiller`) so
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
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed rows including `workflow` and structured `admission_error`. Missing or malformed admission state is converted to `dependency_validation_failed`, `blocked: true`, action `admission_error`, and no command. Envelope shape is hard-validated while forward schema versions remain best-effort. |
| `Hive::Daemon::OperationalSnapshot` | `lib/hive/daemon/operational_snapshot.rb` | Private daemon-to-status observation channel. `Assembler` publishes `started`, `failed`, and revalidated `complete` tick records; completion time starts the validity window, SIGHUP recalculates it from the reloaded poll interval, and recovery-exhaustion overlays require the same project, slug, stage, and reason. `Store` atomically persists records under owner-private path/inode checks; `Reader` accepts only the live daemon generation, complete phase, supported schema, and unexpired validity window, degrading every other condition to explicit unavailable/stale/invalid evidence. |
| `Hive::Daemon::StatusReport` | `lib/hive/daemon/status_report.rb` | Shared `hive-daemon-status` producer for `hive daemon status --json` and hivebox. Builds the PID/service/binary/update-nudge envelope as a plain hash, exposes `running_state`, `payload`, and web-safe `safe_payload`, bounds `installed_binary --version` probes to 10s, and owns `BINARY_DRIFT_STATES` / `BINARY_DRIFT_ACTIONABLE` so the CLI producer and web repair affordance read the same enum source. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Owns non-task ancillary children such as digest and patrol jobs. Task-stage agents use [[modules/attempts]] and are never adopted with `wait2` or terminated on daemon shutdown. |
| `Hive::Conditions::AttemptObserver` | `lib/hive/conditions/attempt_observer.rb` | Observes reconciled terminal/lost durable attempts. For coding execute attempts it idempotently journals the current `AgentHealthy` fact and rebuilds the projection: only a terminal `succeeded` receipt is satisfied; failed/cancelled/lost outcomes fail closed. Confirmed deliveries are memoized in-process before task lookup/journal parsing; restart rechecks the durable journal once. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::PlanApproval` | `lib/hive/daemon/plan_approval.rb` | Safely turns daemon-enabled `3-plan` approval pauses into `hive develop ... --from 3-plan` dispatches by validating command shape and flipping `WAITING` to `COMPLETE`. |
| `Hive::Daemon::StaleAgentHealer` | `lib/hive/daemon/stale_agent_healer.rb` | Rewrites stale `AGENT_WORKING` markers to `ERROR reason=agent_died` or `ERROR reason=agent_orphaned`, while skipping live controller slots and half-migrated projects. It also repairs wedged `REVIEW_WORKING` rows when the recorded Claude child is dead, the review lock holder is still alive, and child-process inspection proves that holder has no remaining children: it logs `reason=review_agent_died` with the original phase/pass, clears the stale marker, terminates the stuck holder, and removes `.lock` so the daemon can retry review normally. Retryable terminal markers such as `8-finalize` `ERROR reason=unpushed_commits` plus non-review terminal agent-loss `ERROR reason=tmux_session_terminated` / `reason=agent_orphaned` are cleared with a bounded per-process retry budget so interrupted sessions can rerun. A narrower timeout path clears `ERROR reason=timeout` exactly once, only on `5-open-pr` and `7-artifacts`, because those re-entries are side-effect-safe (`open_pr_already_open` / idempotent `artifact.md` recollection). `limits_reached` markers (review `REVIEW_ERROR` from reviewers/triage/fix, or single-agent `ERROR` in any stage) use a distinct unbounded readiness policy: the provider reset estimate remains visible in `retry_after`, while the daemon retries one interval after the latest quota marker mtime (default 1h, env `HIVE_LIMITS_RETRY_COOLDOWN_SEC`). Each repeated wall writes a fresh marker and starts the next interval; a successful top-up/reset/account-switch attempt stops producing the marker and resumes normally. Non-limit operational failures also auto-retry under the bounded budget so the daemon advances them instead of parking for a human: `ERROR reason=ensure_clean_on_exit_failed` (any worktree-owning stage — the rerun re-applies the scope-checked auto-commit rather than bypassing it, so genuinely out-of-scope residue still re-fails and parks), `REVIEW_ERROR phase=reviewers reason=all_failed` (every reviewer crashed for a non-limit reason; a total usage-limit instead sets `reason=limits_reached` and takes the periodic readiness path), `REVIEW_ERROR phase=fix reason=fix_failed message="claude stop hook did not signal completion"` for the legacy Claude stop-hook completion bug, and `REVIEW_ERROR phase=fix` auto-commit failures (`fix_auto_commit_scope_failed` / `fix_auto_commit_sign_policy_failed` / `fix_auto_commit_signing_failed`). The integrity/operator reasons `fix_status_check_failed`, `fix_tampered`, generic `fix_failed`, and `dirty_worktree` stay manual. The operator-facing bot/TUI still routes `ensure_clean_on_exit_failed` through `ERROR_MANUAL_ONLY_REASONS` as the post-exhaustion "inspect manually" backstop — the daemon retries first, a human sees it only after the budget is spent. `3-plan` is the special terminal-error case: after any successful terminal `ERROR` clear there, including terminal agent-loss or an eligible `limits_reached` probe, it queues `hive plan <slug> --from 3-plan` through `DispatchRequestQueue` and logs `heal_requeued`, because an empty markerless `plan.md` otherwise classifies straight back to `:error`. |
| `Hive::Daemon::RecoverableErrorHealer` | `lib/hive/daemon/recoverable_error_healer.rb` | Runs after `StaleAgentHealer` and before normal dispatch. It auto-clears only the fixed v1 recoverable terminal-error allowlist (`implementer_failed` with a Codex 401 missing bearer/basic-auth signature, and `claude_launch_failed`) after the work area is safe, the dependency health signal changed or the fallback window elapsed, backoff/budget allow it, and health probes pass. Clears are equivalent to manual `hive markers clear`; `3-plan` clears also enqueue `hive plan --from 3-plan`. The global kill-switch is `daemon.auto_retry.enabled: false`. Audit routing is asymmetric: only `auto_retry` and `auto_retry_skipped` are in `Hive::Events::EVENT_TYPES`, so only those two reach the task `events.jsonl` channel; the exhausted path emits its task event as `auto_retry_skipped` (not `auto_retry_exhausted`), and a non-allowlisted/unknown reason is suppressed from the task channel entirely (daemon-log audit only, to avoid a "not retried" line on every unrelated domain failure). All four event names — `auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, `auto_retry_failed` — reach the daemon log. |
| `Hive::Daemon::DisplayNameBackfiller` | `lib/hive/daemon/display_name_backfiller.rb` | Tick-time self-heal for tasks whose one-shot name generation at `hive new` never landed (agent/codex outage). It skips admission-error rows and uses `TaskMeta.read_for_admission`, so corrupt metadata is never treated as a blank name. For a healthy row whose `display_name` is nil/blank, it re-spawns fire-and-forget `hive generate-name <folder>`, mirroring `Hive::Commands::New#spawn_name_generator` (detached, pgroup, logged to `<state_home>/logs/display-name.log`, fully rescued). Anti-churn: an `@inflight` map stores `{pid, at}` per folder, uses the shared `Hive::ProcessKill.pid_alive?` `kill(0)` probe plus `MAX_INFLIGHT_AGE_SEC = 120` to avoid both double-spawns and reused-pid/EPERM pinning, `max_per_tick` (default 2) bounds spawns, and a set name is a natural fixed point. Unexpected row/reap/spawn errors degrade through `:fatal` logging while preserving the no-raise tick contract. Purely additive — never touches markers or dispatch. Logs `display_name_backfill`. |
| `Hive::Daemon::TaskIdBackfiller` | `lib/hive/daemon/task_id_backfiller.rb` | Tick-time self-heal for tasks created outside `hive new` (hand-made folder, one `mv`-ed in) whose `meta.yml` has no `id` — `hive new` allocates ids from `Hive::TaskCounter`, so a task that skipped it shows a blank id in TUI, status, and dependency refs. It skips admission-error rows and corrupt strict metadata reads, so allocating an id cannot replace damaged dependency evidence. For a healthy row whose `Hive::TaskMeta` `id` is nil it allocates `TaskCounter.next!`, writes it via `TaskMeta.update_id` (every other meta field preserved), and commits the meta on `hive/state` under the per-project commit lock (`Hive::Lock.with_commit_lock`, as every durable committer does) with the per-task `hive_commit(stage_name:, slug:, action: "id-assigned")` call. The `task_id_backfill` event carries `committed:` so a swallowed commit (lock timeout / git error) is visible rather than masquerading as fully durable. Synchronous (no spawn/inflight — assignment is instant), `max_per_tick` (default 5) bounds the per-tick commits, and an assigned id is a natural fixed point. Guards `File.directory?(folder)` first so a row that outlived its folder (e.g. `hive drop` between snapshot and tick) is NOT resurrected by `TaskMeta.write`'s `mkdir_p`. Row/commit errors degrade through `:fatal` / `task_id_backfill_commit_skipped` logging while preserving the no-raise tick contract. Purely additive — never touches markers or dispatch. Logs `task_id_backfill`. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Polls `gh pr view --json state` for tasks at 8-finalize/`:complete` and for a narrow set of finalize `ERROR` rows whose PR can still be retired after merge (`git_status_failed`, `claude_launch_failed`). Poll subprocesses use the bounded `Hive::Gh` transport; architecture-enabled projects take that poll timeout from the same absolute reconciler deadline as catch-up and exact-PR hydration. On `MERGED`, durable architecture intake must succeed before it returns an archive dispatch. Deadline deferral leaves the current/later entries for the next tick without burning retry budget; real poll/intake failures retain their consecutive counter until the whole merged-intake step succeeds, then back off and eventually drop visibly. |
| `Hive::Daemon::RefactorPatrolMergeReconciler` | `lib/hive/daemon/refactor_patrol_merge_reconciler.rb` | Converges finalize observations and incremental exact-host GitHub catch-up into one checksummed, write-once manifest per repository/PR/merge occurrence. Catch-up plus every exact-PR hydration later in the same dispatcher tick share one absolute monotonic budget; bounded call slices and rotating project order keep one slow repository or a batch of merges from blocking the daemon. Persisted GitHub backoff begins at observed failure time (tick wall anchor plus monotonic elapsed), not stale tick start. First enablement still seeds a current high-water baseline instead of importing history; the authoritative checkpoint remains schema v2. |
| `Hive::Daemon::RefactorPatrolMergeProgressStore` | `lib/hive/daemon/refactor_patrol_merge_progress_store.rb` | Crash-safe `reconciler-progress.json` sidecar for page cursors, accumulated merge identities, intake position, and GitHub retry state. It binds continuation to registration/repository identity plus the base v2 checkpoint fingerprint, writes atomically, fsyncs directory-entry changes, quarantines unsafe shapes/identity drift, and persists bounded exponential backoff with jitter. |
| `Hive::Daemon::RefactorPatrolScheduler` | `lib/hive/daemon/refactor_patrol_scheduler.rb` | Exposes oldest-first discovery/action candidates, validates exact registration and repository ownership, pins new discovery to the freshly fetched committed default branch, reuses a partial job's durable `analysis_sha` independently of the registered checkout, claims discovery with generation/liveness evidence, emits job-bound result paths, durably surfaces unavailable project config, and checkpoints only matching schema-valid completion envelopes. A clean quota-bounded batch checkpoints completed feature results with `complete: false` and no synthetic review error. Retryable failures normally use a 60-second backoff; a partial envelope whose every error proves a shared daily token limit or the architecture-only unmetered daily backstop is exhausted sleeps until the next UTC day instead of churning once per minute. Architecture launch count follows the durable merge queue and is accounted separately from ordinary patrol's daily launch count; per-cycle capacity still bounds each child. |
| `Hive::Daemon::PatrolArbiter` | `lib/hive/daemon/patrol_arbiter.rb` | Shares each project's patrol-scan capacity between ordinary and architecture patrol and persists alternation state so either ready kind eventually runs. |
| `Hive::Daemon::DigestSchedulerBase` | `lib/hive/daemon/digest_scheduler_base.rb` | Shared daily-digest lifecycle: one pending date, cancellation, bounded failure backoff, dispatch envelope construction, observable tolerant state reads, and atomic cursor persistence. Concrete schedulers retain their cadence and cursor rules. |
| `Hive::Daemon::DigestScheduler` | `lib/hive/daemon/digest_scheduler.rb` | Global daily merged-PR changelist cadence. Persists `last_digested_date` in `<state_home>/digest_state.json` through the shared digest scheduler lifecycle, applies a first-run no-history guard, computes owed Europe/London calendar days after midnight, caps catch-up with `digest.max_catchup_days`, and emits one `hive digest --date D --json` dispatch at a time. |
| `Hive::Daemon::DispatchRequestQueue` | `lib/hive/daemon/dispatch_request_queue.rb` | File-backed delivery queue (`<state_home>/dispatch_requests/*.json`) for Telegram bot, hivebox web/repair, and 3-plan healer requests. Current v3 carries task-generation, predecessor-attempt, and inherited-output intent while pending v2 remains readable; both keep the closed `requestor=bot|healer` contract. It allowlists state-mutating verbs (`run develop brainstorm plan review open-pr artifacts finalize archive markers daemon`), with `daemon` restricted to `hive daemon install --force` under the `__global__` sentinel. Task requests honor status-row dependency waits and admission errors before durable attempt admission; marker repair stays exempt. Claims store the resolved attempt and generation, follow loss successors, and complete from terminal receipts. Everything else is rejected with `:dispatch_request_rejected`. The single-dispatcher invariant lives here: producers write, the daemon dispatches. See [[architecture]] §"Single-dispatcher contract". |
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
            ├─ Hive::Daemon::PrMergeWatcher      (bounded Hive::Gh gh pr view)
            ├─ Hive::Daemon::RefactorPatrolMergeReconciler (incremental merge manifests/high-water)
            ├─ Hive::Daemon::RefactorPatrolMergeProgressStore (restart-safe page/intake cursor)
            ├─ Hive::Daemon::PatrolArbiter       (ordinary/architecture fairness)
            ├─ Hive::Daemon::RefactorPatrolScheduler (durable jobs/actions)
            ├─ Hive::Daemon::DigestScheduler     (<state_home>/digest_state.json)
            ├─ Hive::Daemon::StaleAgentHealer    (AGENT_WORKING repair)
            ├─ Hive::Daemon::RecoverableErrorHealer (probe-gated ERROR retry)
            ├─ Hive::Daemon::DisplayNameBackfiller (missing display_name retry)
            ├─ Hive::Daemon::TaskIdBackfiller    (missing meta id assign)
            └─ Hive::Daemon::Policy              (pure decisions)
```

Lease-backed `attempt_lost` outcomes bypass legacy stale-marker discovery and
`RecoverableErrorHealer`. `StaleAgentHealer#heal_attempt_losses` alone applies
the persisted generation retry budget, after verified orphan cleanup and dirty
capture, and dispatches a same-generation successor through the shared attempt
dispatcher.

`run_forever` wakes at `daemon.fast_poll_sec` (default 1s) for a cheap
probe: non-blocking child reap plus mtime stats of state files and stage
directories seen on the last full status scan. A child exit or mtime
change triggers a full `tick` immediately; otherwise
`daemon.poll_interval_sec` (default 30s) remains the backstop full-scan
cadence for changes the cheap probe cannot see.

Each full tick first publishes a `started` record, then reconciles durable
attempts, processes normalized loss, and publishes lease-first capacity. It
then runs: reap ancillary children -> enforce child
timeouts -> prune dispatch-result notices -> **tick the digest scheduler** ->
fetch status -> heal stale agent markers -> heal recoverable terminal errors -> backfill missing display names ->
backfill missing meta ids -> drop merge watches for every held row -> tick the PR-merge watcher -> **process dispatch requests** -> patrol dispatches
-> per-row dispatch -> prune baselines -> refresh cheap-probe mtime
fingerprints. During per-row dispatch, whitelisted `8-finalize` `ERROR`
rows (`git_status_failed`, `claude_launch_failed`) are enqueued into the
merge watcher before the generic policy table skips `error` rows. Because
the watcher tick already ran earlier in the same full tick, a newly
enqueued row is polled on a later tick; the watcher emits an archive
command with `--recover-merged-error-reason` only after GitHub reports the
PR as `MERGED`.
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
recovery exhaustion, and per-task owner/reason. Failed reconciliation/status
or failed revalidation publishes `failed`. Snapshot age starts at the actual
completion sample rather than the tick-start sample, and a SIGHUP poll-interval
reload immediately reconfigures the assembler's next validity window.

Durable admission results retain their real scheduler meaning in this record:
only an accepted attempt is `dispatched`; an already-live attempt is
`in_flight`, while capacity deferral, terminal replay, lost attempts, invalid
predecessors, and launch handoff failures keep distinct owner/reason evidence.
Recovery-exhaustion evidence is joined only to the same project, slug, stage,
and marker reason, so a task that advances cannot inherit an older recovery
blocker.

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

Durable task admissions use `Attempts::ConfiguredDispatcher`: it resolves the
task and reloads that project's attempt heartbeat, stale, launch, and
first-heartbeat timers for every initial or loss-successor dispatch. A daemon
crash between queue preclaim and attempt-ID stamping is repaired on restart by
looking up the immutable attempt `request_id`; the repaired claim is persisted
before normal live/terminal/lost delivery reconciliation continues.

On Linux the shipped systemd-user unit uses `KillMode=process`. Service
restart therefore replaces only the daemon process; detached durable-attempt
wrappers and workers remain alive for the first reconciliation pass to adopt,
rather than being killed as cgroup children and replayed.

Digest dispatches happen before status fetch because they are global, not
project-row driven. The dispatcher tracks them with synthetic project/stage
`digest/digest`; when the child is reaped, the scheduler advances its cursor
only on exit 0. The dry-run pseudo-child reap path mirrors the same completion
hook so dry-run daemons do not wedge after one digest dispatch; if the scheduler
cursor write fails there, the dispatcher logs `:fatal` and keeps the tick alive
instead of crashing. Scheduler `tick` and `complete` calls are wrapped so digest
state I/O failures log `fatal` with `keeping_previous: true` instead of
crashing the poll loop. Dry-run digest pseudo-children use the same completion
hook when reaped, so a dry-run daemon does not leave the scheduler pending
forever after the first digest dispatch.

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

For an architecture-enabled project, `PrMergeWatcher` asks the reconciler for
the remaining deadline before it polls PR state. A spent budget defers before
starting `gh`; otherwise the poll receives the smaller of the remaining slice
and its explicit watcher cap. Projects outside architecture intake retain the
same bounded 60-second fallback. A hung state poll therefore becomes ordinary
watcher failure/backoff instead of pinning the dispatcher indefinitely.

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
also suppress `ready_to_archive` merge polling. The dispatcher logs admission
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

The daemon has two narrowly-scoped marker writers — both are
state-machine completions, not forward workflow advancement. The marker's
stage does not move; the only same-stage workflow enqueue is the
`3-plan` healer exception described below.

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
   task-lock generation, and clears only the matching marker while holding the
   claim; a replacement holder or failed claim leaves the marker untouched.
   It then logs `reason=review_agent_died` with the prior `phase`/`pass`, so the
   daemon can retry the interrupted phase. If child inspection fails, or
   children still exist, it leaves the row alone. It also auto-clears retryable
   review errors with no live task lock: `REVIEW_ERROR reason=review_agent_died`,
   and `REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure` when the
   pass-specific `reviews/errors-NN.md` contains only
   `tmux_session_terminated before writing expected output file` reviewer
   failures. It also auto-clears `8-finalize` `ERROR reason=unpushed_commits`
   with no live task lock, and treats terminal
   `ERROR reason=tmux_session_terminated` or `reason=agent_orphaned` as
   retryable agent-loss markers in every non-review stage
   (`2-brainstorm`, `3-plan`, `4-execute`, `7-artifacts`, `8-finalize`). For
   `3-plan`, clearing alone is insufficient: the owning run's artifact can be
   an empty `plan.md`, which `TaskAction#incomplete_plan_artifact?` classifies
   as markerless `:error`, a row the daemon policy skips. After any successful
   terminal `ERROR` clear on `3-plan` (currently terminal agent-loss and
   elapsed `limits_reached`), the healer therefore writes a dispatch request
   for `hive plan <slug> --project <project> --from 3-plan` with
   `requestor=healer` / `trigger=terminal_agent_loss` and logs
   `heal_requeued`. The trigger name is inherited from the original requeue
   path, but the behavior is now intentionally broader. That request still
   goes through the normal dispatch queue gates: allowlist, expiry,
   per-slug in-flight, capacity, cooldown, and quarantine. If the marker clear
   succeeds but the request write raises, the healer logs
   `heal_requeue_failed` with the manual `hive plan ... --from 3-plan`
   remediation instead of `marker_heal_failed`, because the marker is already
   gone and a later healer tick cannot retry that same match. **Usage/credit limits self-heal through
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
   and clears it once one cooldown interval has elapsed, even when the provider
   advertises a later reset or the stamp is missing/malformed. A repeated wall
   writes a fresh marker and therefore starts the next interval; successful
   usage resets, top-ups, or account switches stop producing the marker. These
   readiness attempts are unbounded and do not consume the bounded recovery
   budget used by task failures. Limit heals log `reason=limits_reached`
   (terminal path) / `reason=reviewer_limits_reached` (review path) to
   distinguish them from tmux-death retries. The clear matches the observed marker's
   `marker_id` when present, falling back to the legacy `reason` guard only for
   old markers without ids. Once that guard succeeds, healer-managed clears
   purge shadowed marker history atomically; generic state-file agents append
   terminal markers after Hive's working marker, so removing only the current
   error could otherwise reveal a dead marker from an earlier attempt and
   strand redispatch behind another grace cycle. Retry accounting is keyed by project, slug, stage,
   and marker reason, not by marker id, because retryable terminal failures can
   mint a fresh `marker_id` for the same task. After a successful clear,
   it records the pre-clear state-file mtime in the dispatch baseline map so the
   marker-clear rewrite looks like a settled edit-resume change on the next
   status read rather than a first-sight row to strand via `record_baseline`.

   `ERROR reason=timeout` has a narrower rule than the other terminal-error
   paths: only `5-open-pr` and `7-artifacts` are auto-cleared, and only once
   (`TIMEOUT_RECOVERY_LIMIT = 1`). The premise is marker-skip stranding in tmux
   mode, where the agent finished the externally visible work but returned to
   idle before writing the terminal marker. Open-pr re-entry observes the
   already-open PR and returns through the idempotent `open_pr_already_open`
   arm; artifacts re-runs its summary collection into `artifact.md`. Other stage
   timeouts stay manual because their side effects are not proven safe to replay.
   Exhaustion logs `reason=stage_timeout` with manual rerun / marker-clear
   remediation.

   Clearing the marker lets the daemon rerun the owning stage; finalize still
   performs its existing auth check, clean-exit scope check, optional residue
   commit, and push (in that order). Manual-only errors such as
   `reason=ensure_clean_on_exit_failed` and repository-state failures such as
   `reason=git_status_failed` are left red because they need operator
   inspection while the PR is still open. If GitHub later reports the
   task's PR as `MERGED`, `PrMergeWatcher` may archive a whitelisted
   finalize error by dispatching `hive archive` with
   `--recover-merged-error-reason <reason>`; the archive command accepts
   only a matching current `ERROR reason=<reason>` marker after confirming
   the `pr.md` URL still reports `MERGED`, so the stale local worktree does
   not have to be healthy merely to retire an already merged PR. Except for
   periodic `limits_reached` readiness attempts, auto-clears are bounded per
   daemon process by failure signature (default 3 clears); repeated identical
   failures stay red after the budget is exhausted so a persistent
   infrastructure break cannot churn forever. The budget is in-memory only: a
   daemon restart or SIGHUP config reload rebuilds the healer (`dispatcher.rb`
   reconstructs `StaleAgentHealer` on reload without a persisted limit),
   dropping the accumulated counts so an exhausted row becomes eligible again.
   The healer logs `marker_healed`, `marker_heal_failed`, and a one-shot
   `marker_heal_exhausted` event when a bounded recovery path gives up; the
   exhausted event carries `budget_scope=per_process` and
   `suggested_next_action=manual_fix` so operators do not mistake it for a
   persisted terminal state.

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
post-completion refresh, AND prune — so there is no batched loss window
for the critical value; mtimes are stored at microsecond resolution and
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
that task wrapper in `ChildSupervisor`. Current writers emit request v3 and
readers accept pending v2/v3. See [[modules/attempts]].

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
`<state_home>/dispatch_requests/`. The same queue is also reused internally by
`StaleAgentHealer` for the `3-plan` terminal-error rerun described above.
The daemon tick consumes `DispatchRequestQueue.pending`, validates the argv
allowlist, and resolves task verbs through durable admission. Request IDs stay
on the delivery while attempt IDs own execution; receipt reconciliation
unlinks the claim and logs completion.

Current request schema is v3, adding generation intent, predecessor attempt,
and inherited output references. Pending v2 deliveries remain readable and
their generation is inferred under the same ownership lock.

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
(current writers emit `hive-dispatch-request.v3`); mutable claim metadata
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
long-lived `ConfiguredDispatcher` reloads the task project for lease timers and
the global daemon block for verb timeout, kill grace, and global, per-project,
and daily admission caps on every initial attempt and loss successor. A global
config change therefore affects the next admission without replacing the
daemon, while each already-running wrapper keeps its frozen launch policy.
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

Bot and web recovery flows can be two-step operations: clear the recovery
marker, then retry the workflow verb. Producers write only the first request
and store later argv arrays in `<request_id>.sequence`. On successful reap
(`exit_code == 0`), `Dispatcher#promote_dispatch_sequence` writes the next
request with the original routing metadata; on non-zero or nil exit it
discards the sidecar. Hivebox writes the sequence before the first request so a
fast daemon cannot clear the marker before the continuation exists, then
discards that sidecar if the first request write fails. This keeps retries from
running when the marker-clear command failed and prevents orphaned continuations
when enqueueing itself fails.

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
notice for that step so Telegram does not show a marker-clear success
before the actual retry completes.

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
