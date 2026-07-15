---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-07-15
tags: [daemon, module, automation, dispatcher]
---

**TLDR**: Small modules under `Hive::Daemon::*` that together form
the auto-advancing dispatcher (ADR-024). Pure logic (`Policy`,
`ConcurrencyController`) is separated from I/O (`StatusConsumer`,
`ChildSupervisor`, `Logger`, `PrMergeWatcher`, `DigestScheduler`,
`StaleAgentHealer`, `RecoverableErrorHealer`, `DisplayNameBackfiller`) so
the safety-relevant decisions are unit-testable without forking.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Daemon::Policy` | `lib/hive/daemon/policy.rb` | Pure switch over `Hive::Schemas::TaskActionKind`, stage/workflow context, mtime debounce, and `answers_pending` → `:dispatch` / `:poll_for_merge` / `:wait_for_debounce` / `:wait_for_answers` / `:record_baseline` / `:skip`. Source of truth for "should this row fire a child?". |
| `Hive::Daemon::ConcurrencyController` | `lib/hive/daemon/concurrency_controller.rb` | In-memory budget gate: caps (global / per-project / per-day rate plus per-project patrol scans), WRONG_STAGE protective backoff, transient backoff schedule, quarantine, dropped projects, last-dispatched mtime tracking. `Dispatcher#reload_config!` applies reloaded limits through `update_limits` on this same object so SIGHUP changes admission immediately without discarding runtime state. SUCCESS exits do not cool down; the next stage may dispatch immediately. The last-dispatched mtime map is write-through-persisted via an injected `DispatchBaselines` store so it survives restart (see "Persisted dispatch baselines" below); everything else is intentionally in-memory. |
| `Hive::Daemon::DispatchBaselines` | `lib/hive/daemon/dispatch_baselines.rb` | Crash-safe JSON store for the `[project, slug] → state_file_mtime` baseline map (`daemon_dispatch_baselines.json` under the state home). Atomic write + fail-closed load; mirrors `Hive::UpdateCheck::State`. Stops answered `needs_input` tasks being re-stranded across a daemon restart. |
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed `Row` records including `workflow`. Validates the envelope SHAPE (missing/wrong `schema`, `ok=false`) as a hard `Result(ok: false)`, but tolerates schema-VERSION skew (see "Forward-tolerant schema-version skew" below) so a binary/process version mismatch never crashes a tick. Coerces `tasks[].live_task_lock` to strict boolean so daemon consumers can detect a live runner before a Claude PID is attached, and carries marker attrs so recovery code can preserve `REVIEW_WORKING phase/pass` when rewriting markers. |
| `Hive::Daemon::StatusReport` | `lib/hive/daemon/status_report.rb` | Shared `hive-daemon-status` producer for `hive daemon status --json` and hivebox. Builds the PID/service/binary/update-nudge envelope as a plain hash, exposes `running_state`, `payload`, and web-safe `safe_payload`, bounds `installed_binary --version` probes to 10s, and owns `BINARY_DRIFT_STATES` / `BINARY_DRIFT_ACTIONABLE` so the CLI producer and web repair affordance read the same enum source. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Spawns `hive ...` subprocesses with `pgroup: true`; writes the latest daemon-dispatched child output under the durable XDG state directory at `logs/daemon-children/<project>/<slug>/daemon-run.log` (tmpdir is only the standalone-caller fallback), outside the tracked project state worktree; truncating the per-task file on each run bounds persistent storage; reaps via `Process.wait(-1, WNOHANG)`; parses JSON envelopes from child stdout; supports `terminate_all(grace_sec:)` with TERM→KILL escalation. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::PlanApproval` | `lib/hive/daemon/plan_approval.rb` | Safely turns daemon-enabled `3-plan` approval pauses into `hive develop ... --from 3-plan` dispatches by validating command shape and flipping `WAITING` to `COMPLETE`. |
| `Hive::Daemon::StaleAgentHealer` | `lib/hive/daemon/stale_agent_healer.rb` | Rewrites stale `AGENT_WORKING` markers to `ERROR reason=agent_died` or `ERROR reason=agent_orphaned`, while skipping live controller slots and half-migrated projects. It also repairs wedged `REVIEW_WORKING` rows when the recorded Claude child is dead, the review lock holder is still alive, and child-process inspection proves that holder has no remaining children: it logs `reason=review_agent_died` with the original phase/pass, clears the stale marker, terminates the stuck holder, and removes `.lock` so the daemon can retry review normally. Retryable terminal markers such as `8-finalize` `ERROR reason=unpushed_commits` plus non-review terminal agent-loss `ERROR reason=tmux_session_terminated` / `reason=agent_orphaned` are cleared with a bounded per-process retry budget so interrupted sessions can rerun. A narrower timeout path clears `ERROR reason=timeout` exactly once, only on `5-open-pr` and `7-artifacts`, because those re-entries are side-effect-safe (`open_pr_already_open` / idempotent `artifact.md` recollection). `limits_reached` markers (review `REVIEW_ERROR` from reviewers/triage/fix, or single-agent `ERROR` in any stage) self-heal on a cooldown: the writer stamps `retry_after = now + Hive::AgentLimit::RETRY_COOLDOWN_SEC` (default 1h, env `HIVE_LIMITS_RETRY_COOLDOWN_SEC`) and the healer clears them only once `now >= retry_after`, bounded by the same retry budget; cooldown-wait ticks do not burn budget, and a missing/unparseable stamp stays manual. Non-limit operational failures also auto-retry under the same bounded budget so the daemon advances them instead of parking for a human: `ERROR reason=ensure_clean_on_exit_failed` (any worktree-owning stage — the rerun re-applies the scope-checked auto-commit rather than bypassing it, so genuinely out-of-scope residue still re-fails and parks), `REVIEW_ERROR phase=reviewers reason=all_failed` (every reviewer crashed for a non-limit reason; a total usage-limit instead sets `reason=limits_reached` and takes the cooldown path), `REVIEW_ERROR phase=fix reason=fix_failed message="claude stop hook did not signal completion"` for the legacy Claude stop-hook completion bug, and `REVIEW_ERROR phase=fix` auto-commit failures (`fix_auto_commit_scope_failed` / `fix_auto_commit_sign_policy_failed` / `fix_auto_commit_signing_failed`). The integrity/operator reasons `fix_status_check_failed`, `fix_tampered`, generic `fix_failed`, and `dirty_worktree` stay manual. The operator-facing bot/TUI still routes `ensure_clean_on_exit_failed` through `ERROR_MANUAL_ONLY_REASONS` as the post-exhaustion "inspect manually" backstop — the daemon retries first, a human sees it only after the budget is spent. `3-plan` is the special terminal-error case: after any successful terminal `ERROR` clear there, including terminal agent-loss or elapsed `limits_reached`, it queues `hive plan <slug> --from 3-plan` through `DispatchRequestQueue` and logs `heal_requeued`, because an empty markerless `plan.md` otherwise classifies straight back to `:error`. |
| `Hive::Daemon::RecoverableErrorHealer` | `lib/hive/daemon/recoverable_error_healer.rb` | Runs after `StaleAgentHealer` and before normal dispatch. It auto-clears only the fixed v1 recoverable terminal-error allowlist (`implementer_failed` with a Codex 401 missing bearer/basic-auth signature, and `claude_launch_failed`) after the work area is safe, the dependency health signal changed or the fallback window elapsed, backoff/budget allow it, and health probes pass. Clears are equivalent to manual `hive markers clear`; `3-plan` clears also enqueue `hive plan --from 3-plan`. The global kill-switch is `daemon.auto_retry.enabled: false`. Audit routing is asymmetric: only `auto_retry` and `auto_retry_skipped` are in `Hive::Events::EVENT_TYPES`, so only those two reach the task `events.jsonl` channel; the exhausted path emits its task event as `auto_retry_skipped` (not `auto_retry_exhausted`), and a non-allowlisted/unknown reason is suppressed from the task channel entirely (daemon-log audit only, to avoid a "not retried" line on every unrelated domain failure). All four event names — `auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, `auto_retry_failed` — reach the daemon log. |
| `Hive::Daemon::DisplayNameBackfiller` | `lib/hive/daemon/display_name_backfiller.rb` | Tick-time self-heal for tasks whose one-shot name generation at `hive new` never landed (agent/codex outage). Re-spawns fire-and-forget `hive generate-name <folder>` for any row whose `Hive::TaskMeta` `display_name` is nil/blank, mirroring `Hive::Commands::New#spawn_name_generator` (detached, pgroup, logged to `<state_home>/logs/display-name.log`, fully rescued). Anti-churn: an `@inflight` map stores `{pid, at}` per folder, uses `kill(0)` liveness plus `MAX_INFLIGHT_AGE_SEC = 120` to avoid both double-spawns and reused-pid/EPERM pinning, `max_per_tick` (default 2) bounds spawns, and a set name is a natural fixed point. Unexpected row/reap/spawn errors degrade through `:fatal` logging while preserving the no-raise tick contract. Purely additive — never touches markers or dispatch. Logs `display_name_backfill`. |
| `Hive::Daemon::TaskIdBackfiller` | `lib/hive/daemon/task_id_backfiller.rb` | Tick-time self-heal for tasks created outside `hive new` (hand-made folder, one `mv`-ed in) whose `meta.yml` has no `id` — `hive new` allocates ids from `Hive::TaskCounter`, so a task that skipped it shows a blank id everywhere (TUI, status, digest, dependency refs). For any row whose `Hive::TaskMeta` `id` is nil it allocates `TaskCounter.next!`, writes it via `TaskMeta.update_id` (every other meta field preserved), and commits the meta on `hive/state` under the per-project commit lock (`Hive::Lock.with_commit_lock`, as every durable committer does) with the per-task `hive_commit(stage_name:, slug:, action: "id-assigned")` call. The `task_id_backfill` event carries `committed:` so a swallowed commit (lock timeout / git error) is visible rather than masquerading as fully durable. Synchronous (no spawn/inflight — assignment is instant), `max_per_tick` (default 5) bounds the per-tick commits, and an assigned id is a natural fixed point. Guards `File.directory?(folder)` first so a row that outlived its folder (e.g. `hive drop` between snapshot and tick) is NOT resurrected by `TaskMeta.write`'s `mkdir_p`. Row/commit errors degrade through `:fatal` / `task_id_backfill_commit_skipped` logging while preserving the no-raise tick contract. Purely additive — never touches markers or dispatch. Logs `task_id_backfill`. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Polls `gh pr view --json state` for tasks at 8-finalize/`:complete` and for a narrow set of finalize `ERROR` rows whose PR can still be retired after merge (`git_status_failed`, `claude_launch_failed`). On `MERGED` returns an archive dispatch entry the dispatcher fires. Backs off + drops on persistent gh failures. |
| `Hive::Daemon::DigestScheduler` | `lib/hive/daemon/digest_scheduler.rb` | Global daily digest cadence. Persists `last_digested_date` in `<state_home>/digest_state.json`, applies a first-run no-history guard, computes owed local calendar days after midnight, caps catch-up with `digest.max_catchup_days`, and emits one `hive digest --source <resolved> --date D --json` dispatch at a time. Startup and reload resolve the same `digest.source` contract as manual CLI runs (`merged-prs` default, `shipped` opt-in); in-place reload preserves pending/backoff state. |
| `Hive::Daemon::DispatchRequestQueue` | `lib/hive/daemon/dispatch_request_queue.rb` | File-backed queue (`<state_home>/dispatch_requests/*.json`) of dispatch requests written by producer paths (Telegram bot via `Hive::Bot::DispatchRequestWriter`, hivebox stage-run dispatches and daemon-repair requests, and the 3-plan healer requeue) and consumed by the dispatcher's tick loop. Current wire schema is `hive-dispatch-request.v2`: `requestor` is the closed enum `bot|healer`, and any other `schema_version` is rejected as `unknown_schema_version`. Allowlists state-mutating verbs (`run develop brainstorm plan review open-pr artifacts finalize archive markers daemon`), but `daemon` is further constrained to `GLOBAL_MAINTENANCE_ARGVS` (`hive daemon install --force`) under the `__global__` sentinel so project-scoped requests cannot execute host-global daemon lifecycle commands. Everything else is rejected with `:dispatch_request_rejected`. The single-dispatcher invariant lives here: producers write, the daemon dispatches. See [[architecture]] §"Single-dispatcher contract". |
| `Hive::Daemon::QueueDirectory` | `lib/hive/daemon/queue_directory.rb` | Shared `directory_for(dirname:, state_home:)` helper used by both dispatch queues so the owner-only (0700) per-queue directory invariant — the de-facto auth boundary for the dispatch channel — lives in one place (#253). |
| `Hive::Commands::Daemon` | `lib/hive/commands/daemon.rb` | Thor subcommand surface (`start` / `stop` / `status` / `reload` / `tail` / `install` / `enable` / `disable` / `queue`). Owns PID/signal lifecycle, service installation, per-project enrollment, and read-only dispatch-request queue inspection. `queue` delegates to `Hive::Commands::Daemon::QueueCommand`. |
| `Hive::Commands::Daemon::QueueCommand` | `lib/hive/commands/daemon/queue_command.rb` | Extracted read-only queue-inspection surface (`hive daemon queue list/show/prune`) — touches only `queue_args`/`json`/`hive_home`, orthogonal to the daemon lifecycle, mirroring the `ServiceInstaller` extraction (#254). Internal IO/parse failures are wrapped in `Hive::InternalError` (exit 70). |

## Wiring

```
hive daemon start
  └─ Hive::Commands::Daemon
       ├─ writes ~/Dev/hive/.daemon.pid
       └─ Hive::Daemon::Dispatcher.run_forever
            ├─ Hive::Daemon::Logger              (~/Dev/hive/logs/daemon.log, JSON-line)
            ├─ Hive::Daemon::ConcurrencyController
            ├─ Hive::Daemon::ChildSupervisor     (Process.spawn pgroup: true)
            ├─ Hive::Daemon::StatusConsumer      (Open3.capture3 hive status --json)
            ├─ Hive::Daemon::DispatchRequestQueue (<state_home>/dispatch_requests/*.json)
            ├─ Hive::Daemon::PrMergeWatcher      (Open3.capture3 gh pr view)
            ├─ Hive::Daemon::DigestScheduler     (<state_home>/digest_state.json)
            ├─ Hive::Daemon::StaleAgentHealer    (AGENT_WORKING repair)
            ├─ Hive::Daemon::RecoverableErrorHealer (probe-gated ERROR retry)
            ├─ Hive::Daemon::DisplayNameBackfiller (missing display_name retry)
            ├─ Hive::Daemon::TaskIdBackfiller    (missing meta id assign)
            └─ Hive::Daemon::Policy              (pure decisions)
```

`run_forever` wakes at `daemon.fast_poll_sec` (default 1s) for a cheap
probe: non-blocking child reap plus mtime stats of state files and stage
directories seen on the last full status scan. A child exit or mtime
change triggers a full `tick` immediately; otherwise
`daemon.poll_interval_sec` (default 30s) remains the backstop full-scan
cadence for changes the cheap probe cannot see.

Each full tick runs in order: reap completed children -> enforce child
timeouts -> prune dispatch-result notices -> **tick the digest scheduler** ->
fetch status -> heal stale agent markers -> heal recoverable terminal errors -> backfill missing display names ->
backfill missing meta ids -> tick the PR-merge watcher -> **process dispatch requests** -> patrol dispatches
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

Digest dispatches happen before status fetch because they are global, not
project-row driven. The dispatcher tracks them with synthetic project/stage
`digest/digest`; when the child is reaped, the scheduler advances its cursor
only on exit 0, independent of source. A zero-merge digest is a valid delivered
day and therefore advances. The dry-run pseudo-child reap path mirrors the same completion
hook so dry-run daemons do not wedge after one digest dispatch; if the scheduler
cursor write fails there, the dispatcher logs `:fatal` and keeps the tick alive
instead of crashing.
only on exit 0. Scheduler `tick` and `complete` calls are wrapped so digest
state I/O failures log `fatal` with `keeping_previous: true` instead of
crashing the poll loop. Dry-run digest pseudo-children use the same completion
hook when reaped, so a dry-run daemon does not leave the scheduler pending
forever after the first digest dispatch.

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
like the existing coding `ready_to_*` actions: non-empty command plus no
dependency block returns `:dispatch`; `blocked: true` returns
`:blocked_on_dependency`; nil or empty command returns `:skip`. The coding
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
level, not as a silent advance past a human gate. See ADR-024.

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
   `REVIEW_WORKING`: if the row's `claude_pid_alive` is false, the lock
   holder PID/start-time still match, and `pgrep -P <holder>` proves the
   holder has no children, the healer treats the parent as wedged. It
   logs `reason=review_agent_died` with the prior `phase`/`pass`, clears
   the stale `REVIEW_WORKING` marker, terminates that holder, and deletes
   the task `.lock`, so the daemon sees the row as ready and retries the
   interrupted review phase. If child inspection fails, or children still
   exist, it leaves the row alone. It also auto-clears retryable
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
   gone and a later healer tick cannot retry that same match. **Usage/credit limits self-heal on
   a cooldown:** any `limits_reached` marker — review `REVIEW_ERROR`
   markers written by `Stages::Review` when all reviewers, triage, or fix hit
   provider usage/credit limits, and the
   single-agent `ERROR reason=limits_reached` written by `ClaudeLauncher` /
   `Agent` (any stage, since a limit can hit brainstorm/plan/execute too) —
   carries a `retry_after` ISO8601 stamp set at write time to `now + cooldown`
   (`Hive::AgentLimit::RETRY_COOLDOWN_SEC`, default 3600s = 1h, overridable
   per-process via `HIVE_LIMITS_RETRY_COOLDOWN_SEC`). The healer reads that
   stamp and clears the marker only once `now >= retry_after`, so the parked
   task re-dispatches after the usage window has plausibly reset instead of
   staying red until a human runs `hive markers clear`. A missing or
   unparseable `retry_after` keeps the marker manual (legacy markers predate
   the stamp). The cooldown gate is evaluated *before* the retry-budget
   increment, so cooldown-wait ticks do **not** consume budget — a
   persistently-limited task still gets up to the bounded number of
   cooldown-spaced clears (default 3) before staying red for manual recovery.
   The provider's wall-clock "try again at 4:42 PM" hint is deliberately not
   parsed; the fixed cooldown is the robust default (reset-time parsing is a
   noted future enhancement). Limit heals log `reason=limits_reached`
   (terminal path) / `reason=reviewer_limits_reached` (review path) to
   distinguish them from tmux-death retries. The clear matches the observed marker's
   `marker_id` when present, falling back to the legacy `reason` guard only for
   old markers without ids. Retry accounting is keyed by project, slug, stage,
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
   not have to be healthy merely to retire an already merged PR. Auto-clears are bounded per
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
The daemon's tick loop consumes the queue via
`Hive::Daemon::DispatchRequestQueue.pending`,
validates the argv against an allowlist
(`run develop brainstorm plan review open-pr artifacts finalize
archive markers`), threads the `request_id` through `spawn → reap`
so `reap_completed` can unlink the file and log the lifecycle:

The current strict schema is `hive-dispatch-request.v2`. v2's shape change is
small but breaking by design: `requestor` now accepts `healer` in addition to
`bot`, because the stale-agent healer writes plan rerun requests into the same
queue. The parser is strict-version-matched rather than tolerant here; a
producer that emits a new queue shape requires a coordinated daemon update and
a new schema file before live requests are written.

```
:dispatch_request_observed   request_id=… project=… slug=…
:dispatch_request_dispatched pid=… command=…   (only when dispatched)
:dispatch_request_blocked    reason=in_flight|cooldown|…
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
4. `controller.running_task?` — already in flight for this slug →
   blocked, file stays for the next tick.
5. `controller.can_dispatch?` gate (caps / cooldown / quarantine) —
   blocked → file stays for the next tick.
6. Otherwise → spawn via `dispatch_command`, threading `request_id`
   into `ChildSupervisor#spawn` and `ChildExit#request_id`.

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
`<id>.json.claimed` before the daemon spawns the child. The claimed JSON
stays schema-valid for the dispatch-request version the producer wrote
(current writers emit `hive-dispatch-request.v2`); mutable claim metadata
(`pid`, `process_start_time`, `claimed_at`) lives in a sibling
`<id>.json.claimed.claim` sidecar that is updated after spawn. Claimed
files are invisible to `pending` (the glob matches `*.json`, not
`*.json.claimed`), so a later tick never re-observes them — **each
queued request is dispatched at most once, ever**. The claimed file,
claim sidecar, and any sequence sidecar are unlinked on reap.

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

`ChildSupervisor` enforces a per-child timeout so a wedged `hive run`
can't hold a concurrency slot until daemon shutdown. The timeout is
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

`child_kill_grace_sec` is a **minimum, not a precise timer** (#266):
`enforce_timeouts` runs once per `poll_interval_sec` tick (default 30s),
so the actual SIGKILL can arrive up to one poll interval after the grace
window nominally elapses, and `child_kill_grace_sec: 0` does NOT mean
immediate KILL — it means "KILL on the next tick after the TERM".
Operators tuning the grace for a hard real-time bound should account for
the poll interval.

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
  carries status-command stderr breadcrumbs like a fail-open dependency
  gate or dropped `depends_on`, so it is intentionally not skew-specific)
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
