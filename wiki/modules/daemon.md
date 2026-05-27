---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-05-25
tags: [daemon, module, automation, dispatcher]
---

**TLDR**: Small modules under `Hive::Daemon::*` that together form
the auto-advancing dispatcher (ADR-024). Pure logic (`Policy`,
`ConcurrencyController`) is separated from I/O (`StatusConsumer`,
`ChildSupervisor`, `Logger`, `PrMergeWatcher`, `StaleAgentHealer`) so
the safety-relevant decisions are unit-testable without forking.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Daemon::Policy` | `lib/hive/daemon/policy.rb` | Pure switch over `Hive::Schemas::TaskActionKind`, stage context, and mtime debounce → `:dispatch` / `:poll_for_merge` / `:wait_for_debounce` / `:skip`. Source of truth for "should this row fire a child?". |
| `Hive::Daemon::ConcurrencyController` | `lib/hive/daemon/concurrency_controller.rb` | In-memory budget gate: caps (global / per-project / per-day rate), cooldowns, transient backoff schedule, quarantine, dropped projects, last-dispatched mtime tracking. The last-dispatched mtime map is write-through-persisted via an injected `DispatchBaselines` store so it survives restart (see "Persisted dispatch baselines" below); everything else is intentionally in-memory. |
| `Hive::Daemon::DispatchBaselines` | `lib/hive/daemon/dispatch_baselines.rb` | Crash-safe JSON store for the `[project, slug] → state_file_mtime` baseline map (`daemon_dispatch_baselines.json` under the state home). Atomic write + fail-closed load; mirrors `Hive::UpdateCheck::State`. Stops answered `needs_input` tasks being re-stranded across a daemon restart. |
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed `Row` records. Validates schema version; surfaces parse failures as `Result(ok: false)`. Coerces `tasks[].live_task_lock` to strict boolean so daemon consumers can detect a live runner before a Claude PID is attached. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Spawns `hive ...` subprocesses with `pgroup: true`; reaps via `Process.wait(-1, WNOHANG)`; parses JSON envelopes from child stdout; supports `terminate_all(grace_sec:)` with TERM→KILL escalation. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::PlanApproval` | `lib/hive/daemon/plan_approval.rb` | Safely turns daemon-enabled `3-plan` approval pauses into `hive develop ... --from 3-plan` dispatches by validating command shape and flipping `WAITING` to `COMPLETE`. |
| `Hive::Daemon::StaleAgentHealer` | `lib/hive/daemon/stale_agent_healer.rb` | Rewrites stale `AGENT_WORKING` markers to `ERROR reason=agent_died` or `ERROR reason=agent_orphaned`, while skipping live controller slots, half-migrated projects, and rows with `live_task_lock: true`. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Polls `gh pr view --json state` for tasks at 8-finalize/`:complete`. On `MERGED` returns an archive dispatch entry the dispatcher fires. Backs off + drops on persistent gh failures. |
| `Hive::Commands::Daemon` | `lib/hive/commands/daemon.rb` | Thor subcommand surface (`start` / `stop` / `status` / `reload` / `tail`). Owns the PID file + signal-based stop/reload. |

## Wiring

```
hive daemon start
  └─ Hive::Commands::Daemon
       ├─ writes ~/Dev/hive/.daemon.pid
       └─ Hive::Daemon::Dispatcher.run_forever
            ├─ Hive::Daemon::Logger      (~/Dev/hive/logs/daemon.log, JSON-line)
            ├─ Hive::Daemon::ConcurrencyController
            ├─ Hive::Daemon::ChildSupervisor   (Process.spawn pgroup: true)
            ├─ Hive::Daemon::StatusConsumer    (Open3.capture3 hive status --json)
            ├─ Hive::Daemon::PrMergeWatcher    (Open3.capture3 gh pr view)
            ├─ Hive::Daemon::StaleAgentHealer  (AGENT_WORKING repair)
            └─ Hive::Daemon::Policy            (pure decisions)
```

`Hive::Daemon::Policy` and `Hive::Daemon::ConcurrencyController` have no
I/O at all — fully unit-testable without forking. The other modules
each expose a thin enough seam that mock collaborators (see
`test/unit/daemon/dispatcher_test.rb`) cover the routing behaviour
without spinning up the whole stack.

## Trust boundary

The daemon adds NO new forward-advance approval logic. Workflow-verb
safety is delegated to `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`
(`%i[complete execute_complete review_complete]`). The daemon is a
subprocess caller; it never `File.rename`s task folders or touches
per-task `.lock` files directly. Any misclassification at the `Policy`
level surfaces as `Hive::WrongStage` (exit 4) at the workflow-verb
level, not as a silent advance past a human gate. See ADR-024.

The daemon has two narrowly-scoped marker writers — both are
state-machine completions, not workflow advancement. The marker's
stage does not move and no workflow verb fires from either path.

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
   external `hive run` still holds a verified task lock. The
   `live_task_lock` skip matters during pre-Claude work such as
   auto-rebase, when the runner is active but has not yet written
   `claude_pid` into `.lock`.
   Heal/skip events are logged as `marker_healed` / `marker_heal_failed`.

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
write-throughs on every baseline mutation (first-sight record, dispatch,
post-completion refresh), so there is no batched loss window for the
critical value; mtimes are stored at microsecond precision so the
comparison stays mtime-to-mtime (no wall-clock / sub-second / clock-skew
class of bug — the reason the earlier marker-`ts` approach was rejected).
The dispatcher prunes entries absent from the live status rows once per
**successful** tick (never on a failed/empty fetch), bounding the file to
the live task set. Same-host only.

**Accepted limitation:** if the daemon is down for the *entire* window
between a bot-dispatched brainstorm's `WAITING` write and the user's
answer, no baseline was ever recorded, so the answer becomes the baseline
on first start and the task waits for the next edit. The daemon is
normally up, so the window is tiny; the operator can re-save / `touch`.

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
(the file holding `SCHEMA_VERSIONS`). On every tick it rehashes the
file and compares. On mismatch it logs `version_drift` with the old
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

## Backlinks

- [[commands/daemon]]
- [[commands/status]]
- [[modules/task_action]]
- [[decisions]] (ADR-024)
- [[architecture]]
- [[cli]]
