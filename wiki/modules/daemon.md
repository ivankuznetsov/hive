---
title: Hive::Daemon
type: module
source: lib/hive/daemon/
created: 2026-05-06
updated: 2026-06-03
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
| `Hive::Daemon::Policy` | `lib/hive/daemon/policy.rb` | Pure switch over `Hive::Schemas::TaskActionKind`, stage context, mtime debounce, and `answers_pending` → `:dispatch` / `:poll_for_merge` / `:wait_for_debounce` / `:wait_for_answers` / `:record_baseline` / `:skip`. Source of truth for "should this row fire a child?". |
| `Hive::Daemon::ConcurrencyController` | `lib/hive/daemon/concurrency_controller.rb` | In-memory budget gate: caps (global / per-project / per-day rate), cooldowns, transient backoff schedule, quarantine, dropped projects, last-dispatched mtime tracking. The last-dispatched mtime map is write-through-persisted via an injected `DispatchBaselines` store so it survives restart (see "Persisted dispatch baselines" below); everything else is intentionally in-memory. |
| `Hive::Daemon::DispatchBaselines` | `lib/hive/daemon/dispatch_baselines.rb` | Crash-safe JSON store for the `[project, slug] → state_file_mtime` baseline map (`daemon_dispatch_baselines.json` under the state home). Atomic write + fail-closed load; mirrors `Hive::UpdateCheck::State`. Stops answered `needs_input` tasks being re-stranded across a daemon restart. |
| `Hive::Daemon::StatusConsumer` | `lib/hive/daemon/status_consumer.rb` | Wraps `Open3.capture3("hive status --json")`; returns typed `Row` records. Validates schema version; surfaces parse failures as `Result(ok: false)`. Coerces `tasks[].live_task_lock` to strict boolean so daemon consumers can detect a live runner before a Claude PID is attached. |
| `Hive::Daemon::ChildSupervisor` | `lib/hive/daemon/child_supervisor.rb` | Spawns `hive ...` subprocesses with `pgroup: true`; reaps via `Process.wait(-1, WNOHANG)`; parses JSON envelopes from child stdout; supports `terminate_all(grace_sec:)` with TERM→KILL escalation. |
| `Hive::Daemon::Dispatcher` | `lib/hive/daemon/dispatcher.rb` | The poll-classify-dispatch loop. Glues all of the above. Public `tick(now:)` for tests, `run_forever` for production with TERM/INT/HUP signal traps. |
| `Hive::Daemon::Logger` | `lib/hive/daemon/logger.rb` | One-JSON-line-per-event structured logger. Closed event enum (unknown name raises). Size-rotated. |
| `Hive::Daemon::PlanApproval` | `lib/hive/daemon/plan_approval.rb` | Safely turns daemon-enabled `3-plan` approval pauses into `hive develop ... --from 3-plan` dispatches by validating command shape and flipping `WAITING` to `COMPLETE`. |
| `Hive::Daemon::StaleAgentHealer` | `lib/hive/daemon/stale_agent_healer.rb` | Rewrites stale `AGENT_WORKING` markers to `ERROR reason=agent_died` or `ERROR reason=agent_orphaned`, while skipping live controller slots, half-migrated projects, and rows with `live_task_lock: true`. |
| `Hive::Daemon::PrMergeWatcher` | `lib/hive/daemon/pr_merge_watcher.rb` | Polls `gh pr view --json state` for tasks at 8-finalize/`:complete`. On `MERGED` returns an archive dispatch entry the dispatcher fires. Backs off + drops on persistent gh failures. |
| `Hive::Daemon::DispatchRequestQueue` | `lib/hive/daemon/dispatch_request_queue.rb` | File-backed queue (`<state_home>/dispatch_requests/*.json`) of dispatch requests written by external callers (today: the Telegram bot via `Hive::Bot::DispatchRequestWriter`) and consumed by the dispatcher's tick loop. Allowlists state-mutating verbs (`run develop brainstorm plan review open-pr artifacts finalize archive markers`); rejects everything else with a logged `:dispatch_request_rejected` event. The single-dispatcher invariant lives here: the bot writes, the daemon dispatches. See [[architecture]] §"Single-dispatcher contract". |
| `Hive::Commands::Daemon` | `lib/hive/commands/daemon.rb` | Thor subcommand surface (`start` / `stop` / `status` / `reload` / `tail` / `install` / `enable` / `disable` / `queue`). Owns PID/signal lifecycle, service installation, per-project enrollment, and read-only dispatch-request queue inspection. |

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
            ├─ Hive::Daemon::StaleAgentHealer    (AGENT_WORKING repair)
            └─ Hive::Daemon::Policy              (pure decisions)
```

Each tick runs in order: reap completed children → fetch status →
**process dispatch requests** → handle PR-merge watcher → per-row
dispatch → prune baselines. Dispatch requests come BEFORE the
row-scan so a slug whose request just dispatched this tick is
already in-flight in the controller and the row scan's per-slug
in-flight gate (`controller.running_task?`) keeps the same tick
from double-spawning.

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
- The dispatcher logs the hold as `:skipped reason=answers_pending`.

This is surface-agnostic: it holds whether answers arrive incrementally
via the bot or all at once via a direct edit, and the published
`hive-status` schema is untouched (the daemon parses the file directly).
The bot's own "all answered → enqueue a dispatch request" path then just
races the row-scan to the same gate; the per-slug in-flight gate dedups.

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
for the critical value; mtimes are stored at microsecond resolution,
sufficient given upstream `hive status --json` emits whole-second mtimes.
The comparison stays mtime-to-mtime, never wall-clock — no clock-skew
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

## Single-dispatcher: bot writes requests, daemon dispatches

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

The fix collapses the two dispatchers into one. The bot is
producer-only: it writes a JSON request file via
`Hive::Bot::DispatchRequestWriter.write!` into
`<state_home>/dispatch_requests/`. The daemon's tick loop consumes
the queue via `Hive::Daemon::DispatchRequestQueue.pending`,
validates the argv against an allowlist
(`run develop brainstorm plan review open-pr artifacts finalize
archive markers`), threads the `request_id` through `spawn → reap`
so `reap_completed` can unlink the file and log the lifecycle:

```
:dispatch_request_observed   request_id=… project=… slug=…
:dispatch_request_dispatched pid=… command=…   (only when dispatched)
:dispatch_request_blocked    reason=in_flight|cooldown|…
:dispatch_request_completed  pid=… exit_code=… elapsed_sec=…
:dispatch_request_rejected   reason=invalid_argv|unknown_project|…
:dispatch_request_expired    created_at=…
:dispatch_request_recovered  reason=owner_gone|claim_expired|malformed_claim  (startup claim sweep, C3)
:dispatch_result_written     exit_code=… chat_id=…  (non-zero exit → bot relay, ADV-1)
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
stays a schema-valid `hive-dispatch-request.v1`; mutable claim metadata
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
[[config]] for the knobs.

### Queue sequence continuations

Bot recovery flows can be two-step operations: clear the recovery marker,
then retry the workflow verb. The bot writes only the first request and
stores later argv arrays in `<request_id>.sequence`. On successful reap
(`exit_code == 0`), `Dispatcher#promote_dispatch_sequence` writes the
next request with the original Telegram routing metadata; on non-zero or
nil exit it discards the sidecar. This keeps retries from running when
the marker-clear command failed.

### Failure feedback to Telegram (ADV-1)

Because the daemon (not the bot) now spawns request-driven children and
has no Telegram handle, a non-zero exit of a bot-initiated run used to
be silent for the operator who tapped the button. On a non-zero,
request-driven completion — **including a nil exit_code, i.e. a child
killed by an R-02 timeout signal** — `reap_completed` reads the
request's `chat_id`/`update_id` (from the still-present claimed file,
before unlink) and writes a notice via `Hive::Daemon::DispatchResultQueue`
into `<state_home>/dispatch_results/*.json` (logged `:dispatch_result_written`).
The bot drains that directory each `reaper_loop` iteration
(`Supervisor#drain_dispatch_results`) and relays a `⚠️ <slug>: hive <verb>
failed (exit N | killed)` message to the originating chat. This is the
reverse-direction sibling of the dispatch-request queue; schema
`hive-dispatch-result` v1.

Reliability contract on the consumer side: a notice is removed **only
after the relay is confirmed sent** — if Telegram is down it stays on
disk to retry next tick (never a silent drop). Notices older than
`DispatchResultQueue::EXPIRY_SEC` (1h) are dropped without relaying
(no stale-failure spam), and the daemon prunes them each tick
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
