---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-05-06
tags: [daemon, module, automation, dispatcher]
---

**TLDR**: Six small modules under `Hive::Daemon::*` that together form
the auto-advancing dispatcher (ADR-024). Pure logic (`Policy`,
`ConcurrencyController`) is separated from I/O (`StatusConsumer`,
`ChildSupervisor`, `Logger`, `PrMergeWatcher`) so the safety-relevant
decisions are unit-testable without forking.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Daemon::Policy` | `lib/hive/daemon/policy.rb` | Pure switch over `Hive::Schemas::TaskActionKind` + mtime debounce → `:dispatch` / `:poll_for_merge` / `:wait_for_debounce` / `:skip`. Source of truth for "should this row fire a child?". |
| `Hive::Daemon::ConcurrencyController` | `lib/hive/daemon/concurrency_controller.rb` | In-memory budget gate: caps (global / per-project / per-day rate), cooldowns, transient backoff schedule, quarantine, dropped projects, last-dispatched mtime tracking. |
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed `Row` records. Validates schema version; surfaces parse failures as `Result(ok: false)`. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Spawns `hive ...` subprocesses with `pgroup: true`; reaps via `Process.wait(-1, WNOHANG)`; parses JSON envelopes from child stdout; supports `terminate_all(grace_sec:)` with TERM→KILL escalation. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Polls `gh pr view --json state` for tasks at 6-pr/`:complete`. On `MERGED` returns an archive dispatch entry the dispatcher fires. Backs off + drops on persistent gh failures. |
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
            └─ Hive::Daemon::Policy            (pure decisions)
```

`Hive::Daemon::Policy` and `Hive::Daemon::ConcurrencyController` have no
I/O at all — fully unit-testable without forking. The other modules
each expose a thin enough seam that mock collaborators (see
`test/unit/daemon/dispatcher_test.rb`) cover the routing behaviour
without spinning up the whole stack.

## Trust boundary

The daemon adds NO new approval logic. Forward-advance safety is
delegated to `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`
(`%i[complete execute_complete review_complete]`). The daemon is a
subprocess caller; it never writes markers, never `File.rename`s task
folders, never touches per-task `.lock` files directly. Any
misclassification at the `Policy` level surfaces as `Hive::WrongStage`
(exit 4) at the workflow-verb level, not as a silent advance past a
human gate. See ADR-024.

## Backlinks

- [[commands/daemon]]
- [[decisions]] (ADR-024)
- [[architecture]]
- [[cli]]
