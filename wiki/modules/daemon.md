---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-05-15
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
| `Hive::Daemon::Policy` | `lib/hive/daemon/policy.rb` | Pure switch over `Hive::Schemas::TaskActionKind`, stage context, and mtime debounce → `:dispatch` / `:poll_for_merge` / `:wait_for_debounce` / `:skip`. Source of truth for "should this row fire a child?". |
| `Hive::Daemon::ConcurrencyController` | `lib/hive/daemon/concurrency_controller.rb` | In-memory budget gate: caps (global / per-project / per-day rate), cooldowns, transient backoff schedule, quarantine, dropped projects, last-dispatched mtime tracking. |
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed `Row` records. Validates schema version; surfaces parse failures as `Result(ok: false)`. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Spawns `hive ...` subprocesses with `pgroup: true`; reaps via `Process.wait(-1, WNOHANG)`; parses JSON envelopes from child stdout; supports `terminate_all(grace_sec:)` with TERM→KILL escalation. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Polls `gh pr view --json state` for tasks at 7-finalize/`:complete`. On `MERGED` returns an archive dispatch entry the dispatcher fires. Backs off + drops on persistent gh failures. |
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

The daemon adds NO new forward-advance approval logic. Workflow-verb
safety is delegated to `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`
(`%i[complete execute_complete review_complete]`). The daemon is a
subprocess caller; it never `File.rename`s task folders or touches
per-task `.lock` files directly. Any misclassification at the `Policy`
level surfaces as `Hive::WrongStage` (exit 4) at the workflow-verb
level, not as a silent advance past a human gate. See ADR-024.

The one place the daemon does rewrite a marker on disk is the
`Hive::Daemon::StaleAgentHealer` (PR #113): on every tick, it scans
`AGENT_WORKING` markers whose backing agent isn't actually alive
(dead `claude_pid` or a placeholder marker stamped at stage entry
that no agent ever attached to, older than
`daemon.agent_marker_grace_sec`, default 300s) and rewrites them to
`ERROR reason=agent_died` / `reason=agent_orphaned`. This is healing,
not advancing — the marker's stage doesn't move and no workflow verb
fires. The healer skips rows whose project has a half-migrated
layout (`legacy_stage_dirs`) and rows for which the
`ConcurrencyController` has a live in-flight slot. Heal/skip events
are logged as `marker_healed` / `marker_heal_failed`.

`3-plan`/`needs_input` is the policy exception to the generic
edit-resume debounce. A generated plan in `WAITING` is an approval
pause, not a Q&A file waiting for typed answers. For daemon-enabled
projects the durable approval gesture is `daemon.enabled: true`, so the
policy dispatches the row's `hive develop ... --from 3-plan` command
immediately. Brainstorm, execute, and review `needs_input` rows still
use mtime-baseline + debounce because those states represent actual
user-authored answers or review decisions.

## Backlinks

- [[commands/daemon]]
- [[decisions]] (ADR-024)
- [[architecture]]
- [[cli]]
