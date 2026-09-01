---
title: hive daemon
type: command
source: lib/hive/commands/daemon.rb, lib/hive/daemon/*
created: 2026-05-06
updated: 2026-08-30
tags: [command, daemon, automation, plan-review, json, dogfood]
---

**TLDR**: `hive daemon SUBCOMMAND` is the operator surface for the
auto-advancing dispatcher (ADR-024). One long-running process wakes
every 1s for bounded child-exit/state-mtime probes, refreshes only the changed
task rows, and runs an internal full task-graph scan every 30s as repair. It dispatches
workflow verbs (`hive plan` / `develop` / `open-pr` / `review` /
`artifacts` / `finalize`) on tasks ready to advance, and
auto-archives safely delivered coding tasks from any PR-bearing stage 5–8
after bounded GitHub verification and required architecture intake. It
stops at human-input gates (`_WAITING` markers for Q&A / triage), temporary
retry-safety blocks, and 8-finalize while the PR is still open on GitHub.
Every persisted `ERROR` / `REVIEW_ERROR` except the exact operator-owned
`terminal_outcome_blocked` and `terminal_outcome_invalid` reasons is eligible
for the universal marker-age retry; `RecoveryCoordinator` durably admits only
the exact safe generation before normal policy dispatch. Separately, it ingests merged PRs and
fairly schedules ordinary patrol alongside language-neutral architecture
discovery/action resumes.

## Subcommands

```
hive daemon start [--detach] [--dry-run]
hive daemon stop
hive daemon status [--json]
hive daemon reload
hive daemon tail
hive daemon install [--force]
hive daemon enable  PROJECT | --all  [--json]
hive daemon disable PROJECT | --all  [--json]
hive daemon queue   [list | show <id> | prune]  [--json]
```

| Subcommand | Behavior |
|-----------|----------|
| `start`    | Takes the stable profile-wide daemon-activation lock before inspecting or replacing the PID file (`~/Dev/hive/.daemon.pid`) and retains it until the exact daemon generation publishes operational runtime readiness. A readiness publication failure exits without admitting the daemon. Without `--detach` runs in the foreground. With `--detach` calls `Process.daemon(true, true)` and the parent returns immediately. Both manual modes pin `HIVE_BIN` to the invoked `hive`/`hv` executable when the environment does not already provide an override, so status probes and dispatched children cannot drift to a different packaged Hive on `PATH`. With `--dry-run` logs every dispatch decision but does NOT spawn child `hive ...` processes. Refuses with exit `75 (TEMPFAIL)` if a live daemon already holds the PID file. |
| `stop`     | Sends `SIGTERM` to the running daemon's PID. Waits up to `daemon.shutdown_grace_sec` (default 600s) for the daemon to exit, then escalates to `SIGKILL`. Ancillary children reaped during this drain are completed through their existing scheduler lifecycle before exit, so patrol and digest claims do not wait for lease expiry after a normal restart. Completion is fenced on a verified pre-signal descendant-tree snapshot plus the child's original process group: if either cannot be proven gone, the exit is withheld and the existing claim remains for lease recovery. Signal-derived nil exits count as failure, never success. Idempotent: `stop` with no PID file exits 0 with `daemon not running` on stderr; a stale PID file (process gone) is removed and the call exits 0. With `--json`, emits a `hive-daemon-stop` envelope (fields: `running`, `was_running`, `stale_pid?`, `reason?` — `pid_reused` / `unverified` for safety bailouts). |
| `status`   | Reports running / not running. Exit code 0 if running, 1 if not. With `--json`, emits a `hive-daemon-status` envelope with required producer-owned `runtime` identity, `running`, `pid`, `uptime_sec`, `pid_file`, `log_file`, plus the autostart-service state `service_installed`, `service_enabled`, and `unit_path` (read-only probe) so an agent can tell whether `hive daemon install` has run without a mutating call. The daemon records its runtime in the ownership-checked PID file at startup; status never stamps the observing CLI's identity onto another process, and reports `unknown` for a legacy or unavailable producer. The JSON envelope is produced by `Hive::Daemon::StatusReport`, which also feeds the web dashboard, and reports `installed_binary`, `expected_binary`, `installed_binary_version`, `cli_version`, and `binary_drift` (`none`, `path`, `version`, `unparseable`, `unreadable`, or `not_applicable`). An explicit runtime `HIVE_BIN` is the expected-binary authority before PATH lookup, so a managed web process cannot mistake its private gem wrapper for the daemon binary. Path comparison follows filesystem identity, so a stable service symlink that targets the expected deployment reports `none`; a symlink targeting another deployment still reports `path`. The producer is observation-only and skips update-state temporary-file cleanup. |
| `reload`   | Sends `SIGHUP` to the running daemon's PID, which triggers config reload at the next tick boundary. In-flight children continue uninterrupted. The daemon validates the daemon/update/answer-digest blocks and constructs the replacement healer before replacing live config, so a late loader failure cannot split the advertised retry switch from healer behavior. Reloaded concurrency limits (`max_concurrent_runs`, `max_concurrent_per_project`, `max_runs_per_day_per_project`, and `max_concurrent_patrol_scans`) are applied in place to the existing controller so active-child accounting, cooldowns, quarantine, daily counters, and dispatch baselines survive while new dispatch decisions use the new limits immediately. The structured `config_reloaded` daemon-log event reports all four effective limits for machine verification. Invalid numeric settings, including explicit YAML `null`, fail validation and leave the live limits unchanged. Exit 1 if no daemon running. With `--json`, emits a `hive-daemon-reload` envelope (`ok`, `reason`, `pid`, `message`). |
| `tail`     | `tail -F` semantics on `~/Dev/hive/logs/daemon.log` (self-implemented; doesn't shell out to the `tail` binary). Exit 1 if the log file doesn't exist. |
| `install`  | (Re)writes the platform-native unit file (`~/.config/systemd/user/hive-daemon.service` on Linux, `~/Library/LaunchAgents/local.hive-daemon.plist` on macOS) and starts/enables the service. Platform-neutral inspect/plan/apply mechanics live in `Hive::UserService`; `Daemon::ServiceInstaller` remains the thin Hive adapter for templates, binary resolution, the 900-second restart warning, and command wording. Command-side summaries, JSON envelopes, and typed outcome translation are shared with bot install through `ServiceInstaller::ResultPresenter`. Installers and agent-assisted setup run this by default so daemon autostart is global install-time infrastructure, independent of any project. Without `--force`, refuses to overwrite a pre-existing unit (preserving operator hand-edits); exit `64` (USAGE) with a message pointing at `--force` so automation can branch without clobbering local changes. With `--force`, saves the previous content to a timestamped `<path>.bak-YYYYMMDDTHHMMSSZ` (rotated, never overwritten) via atomic write, then — only when an existing unit was actually overwritten (the `upgraded` outcome) — restarts the running daemon on Linux / unloads-then-loads on macOS so new `Environment=` lines take effect (a first-time `--force` install with no prior unit just starts/enables, no restart). A service-manager failure (systemctl reload/enable, or launchctl load rejecting the unit) exits `70` (SOFTWARE). A host with no systemd-user manager at all is different: the unit is still written, but autostart cannot be enabled, so it exits `0` with the `unsupported` outcome (and `target_path` set to the written unit) — a known-platform limitation, not a failure. With `--json`, every outcome (success and error) emits a `hive-daemon-install.v1` envelope. Units point at the user-facing wrapper path when installers provide it, so bash/Homebrew installs preserve the GEM_HOME/GEM_PATH wrapper across login/reboot; `hv` invocations remain valid when Apache Hive shadows `hive`. Use this after upgrading hive when the unit template has changed or when autostart needs repair. |
| `enable`   | Sets `daemon.enabled: true` in `<project>/.hive-state/config.yml`. This enrolls a project for dispatch; it does not install, start, or autostart the global daemon service. Surgical line-level YAML editor (upsert) preserves comments, key order, and file-mode bits across enable/disable flips; rejects inline-flow `daemon: { ... }`, CRLF endings, and 4-space-indented children before any write. Atomic write goes via tempfile + `flock(LOCK_EX)` + `fsync` + rename; tempfile is ensure-cleaned on rename failure (ENOSPC / EACCES / EXDEV). Pre-flight (`preflight_targets`) validates every target before any write so `--all` cannot half-flip the registry on a bad middle project. Pass a registered project name OR `--all` (mutually exclusive — passing both raises USAGE 64). Exit 64 on missing/unknown target / not-initialised project / no registered projects. With `--json`, emits a `hive-daemon-enroll` envelope on success and an `EnrollErrorKind` JSON error envelope on failure (`missing_project` / `unknown_project` / `project_and_all` / `not_initialised` / `no_projects` / `config` / `internal`); YAML parse failures surface as `Hive::ConfigError` (exit 78). |
| `disable`  | Same shape as `enable`, sets `daemon.enabled: false`. The next dispatcher tick honours the change automatically (per-tick enable-cache invalidation); `hive daemon reload` is optional for instant pickup. |
| `queue`    | Read-only inspection of the dispatch-request rows all adapters write and the daemon consumes. Runtime SQL uses only `hive-dispatch-request.v5`; the irreversible fleet cutover discards pending legacy file queues rather than upgrading them. V5 binds recovery to canonical task/stage/marker/generation identity, carries markerless provider-admission observations, and records `admitted`, `cleared`, `dispatched`, or `terminal` plus owner/remediation and terminal outcome/time. Nonterminal recovery requests do not expire or generic-prune; terminal receipts remain available for bounded replay. Existing `list`/`show`/`prune` JSON and human contracts remain unchanged. |

## What the daemon dispatches

Per `Hive::Daemon::Policy.decide`, the daemon classifies each internal
task-graph row by `next_action.kind` (a `Hive::Schemas::TaskActionKind`
value) and routes. `Hive::Daemon::StaleAgentHealer` runs before this policy
step and submits eligible `ERROR` / `REVIEW_ERROR` observations to
`Hive::Daemon::RecoveryCoordinator`. The coordinator waits for the shared
marker-age cooldown, rejects live ownership or unsafe current-work evidence,
persists the canonical task/marker/generation identity, and owns the guarded
clear plus restart replay. Set
`daemon.auto_retry.enabled` is accepted but inert — automatic retry is unconditional;
explicit operator recovery through the shared API remains available.
The deterministic v5 request does not expire behind admission gates; a crash
before or after clear resumes its persisted phase, while stale identity is
blocked instead of crossing into a replacement task generation.
Each terminal marker is fingerprinted from its reason, provider, status code,
and normalized diagnostic. A changed fingerprint keeps autonomous retries
unbounded. Repetition is exposed as `escalation_tier=degraded`; after three
identical failures at the ladder ceiling the request parks once with
`reason=deterministic_failure`, its fingerprint, and bounded attempt history,
so it stops consuming dispatch slots while other tasks continue. Terminal
recovery cleanup is stage-scoped and cannot erase a prior stage's ladder. The
ladder and repeated-failure evidence are also scoped to the validated Hive
runtime source digest (channel, release version, and dogfood build SHA). A new
build automatically resets a parked request once and runs one guarded probe;
redeploying the same build does not. Legacy digest-less parks receive the same
one-time compatibility rearm. A same-runtime repair to project input,
credentials, or provider state still uses the fresh `workflow.retry` action.
Daemon ticks never migrate task metadata. Missing task ids, display names, and
legacy completion clocks are repaired only by the explicit [[commands/migrate]]
command, so routine scheduling does not compete with stage commits. Recovery
receipts for an id-less task instruct the operator to run `hive migrate --all`;
they never claim a later daemon tick will allocate the id.

| `tasks[].action`      | Daemon action                                |
|-----------------------|----------------------------------------------|
| `ready_to_brainstorm` | Dispatch `hive brainstorm <slug>` (1→2)      |
| `ready_to_plan`       | Dispatch `hive plan <slug> --from 2-brainstorm` (2→3) |
| `ready_to_develop`    | Dispatch `hive develop <slug> --from 3-plan` (3→4) |
| `outcome_evidence_rework` | Validate and dispatch the row's exact digest-bound `hive evidence rework ... --stage 7-artifacts` command (7→4); never synthesize `develop` or `artifacts`. |
| `ready_to_open_pr`    | Dispatch `hive open-pr <slug> --from 4-execute` (4→5) |
| `ready_for_review`    | Dispatch `hive review <slug> --from 5-open-pr` (5→6) |
| `ready_to_artifacts`  | Dispatch `hive artifacts <slug> --from 6-review` (6→7) |
| `ready_to_finalize`   | Dispatch `hive finalize <slug> --from 7-artifacts` (7→8) |
| `ready_to_run` | Dispatch a generic workflow stage once. A stage transition discards the previous stage's persisted mtime baseline so its successor remains eligible. An unchanged state-file mtime after dispatch is surfaced as `markerless_stalled`; marker-driven workflows atomically convert it to `ERROR reason=agent_exited_without_terminal_marker`, while controller workflows enqueue the same generation on the durable markerless recovery route without modifying structured state. After a daemon restart, an older current mtime can recover once only when the baseline was loaded from the persisted store; same-process observations never gain that recovery authority. |
| Any coding task with `pr_url` in stages `5-open-pr` through `8-finalize` | **Observe before policy dispatch.** Persist the exact task generation and PR binding, poll with per-candidate durable backoff, verify the observed head and reachable merge SHA, checkpoint required architecture intake, then use a daemon-owned `remote_merge` closure receipt to move the same generation to `9-done`. This includes recoverable error rows; no marker-reason allowlist or archive child exists. |
| Held PR-bearing task | Keep the candidate in `pr-merge-reconciliation.json` with its hold reason. Current dependency, admission, repository, and PR-identity holds take precedence over historical head drift and do not poll or archive until a later status observation clears them. An `observed_head_changed` hold may poll only the identity-matched bound PR's remote state: `OPEN` or closed-unmerged releases ordinary error recovery so the new generation can be reviewed, while merged, delivered-elsewhere, or ambiguous evidence remains durably blocked before architecture intake or automatic archive and is not polled again. |
| `plan_reviewing` or due `plan_review_retry` at coding `3-plan` | Dispatch `hive plan-review-run ...`. This automation can start/retry critique, perform an already-authorized revision, and verify, but cannot create approvals, answers, waivers, or mandatory downgrades. |
| future `plan_review_retry` | Hold until the projection's `retry_at`; provider/transient evidence remains attached to the same attempt lineage. Exhausted mandatory initial-review series widen from five minutes to a 24-hour cap and reopen automatically instead of requiring a coverage waiver. |
| `plan_review_decision`, `plan_review_unsupported`, or `plan_review_blocked` | Skip. The row names the operator/configuration action; daemon enrollment creates no authority. |
| `ready_to_develop` or `plan_review_degraded` at coding `3-plan` | `PlanApproval.prepare` rewrites to `hive develop ...`, revalidates the exact current plan-review observation under the task lock, and only then flips `:waiting` to `:complete`. A missing/stale/blocked review leaves the marker and folder untouched. |
| `needs_input` (any other stage) | Dispatch only if state-file mtime moved AND `daemon.edit_debounce_sec` elapsed since last edit. The debounce guards mid-save partial drafts. Brainstorm/execute/review WAITING represent actual user-authored answers; auto-dispatch without an edit would either spam the agent or skip real user input. The `[project, slug] → mtime` baseline this compares against is **persisted** (`daemon_dispatch_baselines.json` under the state home, beside `.daemon.pid`), so a daemon restart no longer re-strands a task answered while it was down — see [[modules/daemon]] "Persisted dispatch baselines". **Brainstorm Q&A gate:** mtime-debounce alone can't tell "answered 1 of 3, still going" from "done" — each Telegram answer bumps the file mtime — so a `2-brainstorm` `needs_input` row whose `brainstorm.md` still has unanswered `### Q{n}.` slots is **held** (`Policy :wait_for_answers`, logged `:skipped reason=answers_pending`) until every question is answered. A non-empty, fully answered brainstorm observed before any baseline dispatches after the same debounce instead of consuming the answers as its baseline, so answers written while the daemon was down resume automatically. See [[modules/daemon]] "Brainstorm answers-pending gate". |
| `recover_execute` | Skip — `EXECUTE_STALE` / waiting findings are explicit human-input gates. |
| `recover_review` | Policy skips the row. `REVIEW_ERROR` is handled earlier by the universal recovery scheduler; `REVIEW_STALE` / `REVIEW_CI_STALE` remain explicit operator submissions after inspection or edits. |
| `agent_running`       | Skip — task is in flight; the typed task lease blocks double-spawn, while the skip also preserves capacity accounting. |
| `archived`            | Skip — terminal. |
| `error`               | Keep durable `ERROR` / `REVIEW_ERROR` rows scheduler-owned while the universal healer waits for its shared cooldown and temporary safety gates. Task-bound merge reconciliation runs first, so already merged work closes without another provider attempt when every closure guard passes. |

Markerless automatic advance actions also stop at one failed durable attempt
per unchanged task generation. A later daemon tick replays that terminal
receipt and enters the same `markerless_stalled` recovery path instead of
launching the broken command again. The resulting error or controller recovery
request observes the shared cooldown; an explicit recovery delivery remains
authorized to create a fresh attempt after the cause is fixed. Each terminal
controller-recovery retry receives a deterministic new delivery id, so the
original request remains idempotent without trapping later retries behind its
failed receipt. Advance rows
that still carry a terminal marker retain their existing transition semantics.

`agent_running` rows also feed daemon capacity accounting when status
has positive liveness evidence. The dispatcher counts both rows with a
live recorded Claude PID and rows with `live_task_lock: true` (a verified
`hive run` task-lock holder before Claude has attached). This keeps a
daemon restart during auto-rebase or other pre-agent work from spawning
extra tasks past `max_concurrent_runs` / `max_concurrent_per_project`.

The status-row scan keeps its later-stage-first ordering until the next
authoritative full scan, not only at each individual admission call. If a
higher-priority row reaches a global or durable-attempt capacity boundary,
later dispatchable rows in that frame and in intervening changed-task ticks are
priority-fenced instead of taking a slot that happens to reopen after the
higher row was evaluated. The next full scan starts with no inherited fence
and reconsiders the whole queue. Project and daily caps fence only later rows
from that project, so unrelated projects can still use available global
capacity. Non-dispatch policy rows are still classified and published in the
operational snapshot.

Durable dispatch requests and unrelated status rows use that same
stage-plus-age ordering. Requests age from queue creation and retain FIFO plus
same-task precedence; direct rows age from their state-file mtime. A later
request lends its priority backward through the FIFO prefix when Hive compares
the request lane with direct rows. Older requests still run first, but a
blocked low-priority head cannot make the higher-priority suffix invisible.
This lets an old runnable plan or retry claim a newly opened slot ahead of a
younger request backlog without allowing the request and automatic row for one
task to launch twice. Global and project capacity fences propagate in both
directions across the two sources for the rest of the scan.
Invalid and expired request files are rejected or pruned before that admission
arbitration, so a persistent capacity fence cannot retain stale queue work.

The closed-default policy means any unknown future `TaskActionKind`
value falls through to `:skip` until the daemon is taught about it.

## Architecture-patrol dispatch

Architecture patrol does not enter through `hive status` task rows.
`RefactorPatrolMergeReconciler` combines Hive finalize observations with
exact-host, paginated GitHub catch-up, creates one checksummed v2 manifest per
repository/PR/merge occurrence, and seeds a current high-water baseline on
first enablement instead of importing old history. `PatrolArbiter` then shares
each project's `daemon.max_concurrent_patrol_scans` capacity between ordinary
patrol and architecture patrol, persists alternation across ticks, and selects
architecture occurrences oldest-first so a continuously ready kind cannot
starve the other.

Discovery children run:

```text
hive refactor-patrol PROJECT --job-manifest MANIFEST --json
```

Discovery emits `hive-refactor-patrol.v4` to a job-bound result file consumed
by the supervisor. Completed dispositions are reserved directly in the shared
Patrol Fix `AdmissionStore`, and the job terminalizes. There is no Architecture Patrol
action phase, fixer, issue filer, PR opener, or review handoff.

`refactor_patrol.enabled` controls discovery. Downstream Patrol Fix admission
and workflow capacity are independent of the Architecture scheduler. Missing
`refactor_patrol` config in an existing project remains inert because discovery
is still disabled, and older discovery-only configs do not inherit mutation or
issue-filing authority. See [[commands/refactor-patrol]] for the job and policy model.

## Per-project enrollment

Each project's `.hive-state/config.yml` carries:

```yaml
daemon:
  enabled: true   # asked at `hive init`, default Y; project enrollment only
```

Newly-init'd projects render `daemon.enabled: true` from the init
prompt's default. **Legacy projects** whose YAML predates the `daemon:`
key fall back to `Config::DEFAULTS["daemon"]["enabled"] = false` — same
"don't silently flip legacy projects" pattern ADR-023 used for
stage agents. Operators of legacy projects opt in by adding `daemon: { enabled: true }` and running `hive daemon reload`.

## Concurrency caps

All under `daemon:` in `~/Dev/hive/config.yml`:

| Key | Default | Purpose |
|-----|---------|---------|
| `poll_interval_sec` | 30 | Minimum completion-to-start interval between periodic full status repair scans. Min 5. Slow periodic scans cannot chain; ancillary completion can still request an immediate follow-up scan. |
| `fast_poll_sec` | 1 | Cheap wake cadence for child reaps and a rotating batch of at most 64 tracked state-file mtime probes between full scans. Only exact changed task rows refresh; dependency-bearing rows wait for the full scan. Min 1. |
| `auto_retry.enabled` | — | **Inert.** Retired as a kill switch: `ERROR` / `REVIEW_ERROR` retries are unconditional and follow one backoff ladder. The key is still shape-validated so a typo fails loudly, but setting it changes nothing. Pause a project with `daemon.enabled: false` instead. |
| `edit_debounce_sec` | 30 | Settle window for `kind: edit` resumes. 0 disables debounce. |
| `pr_merge_poll_interval_sec` | 300 | Durable per-candidate merge reconciliation cadence. Min 60 to respect GitHub rate limits; failure counts remain uncapped and backoff is persisted. |
| `max_concurrent_runs` | 3 | Global cap. Raise carefully — multiplies cost ceiling. |
| `max_concurrent_per_project` | 3 | Per-project burst cap; set below the global cap only when you want cross-project sharing. |
| `max_runs_per_day_per_project` | 50 | Circuit breaker for runaway loops. |
| `transient_retry_backoff_sec` | 60 | First retry hold for a durable task attempt that exits `75 (TEMPFAIL)`; also the base of the ancillary-child `60 → 120 → 300 s` transient backoff schedule. |
| `shutdown_grace_sec` | 600 | TERM→KILL window for in-flight children on `daemon stop`. |
| `child_timeout_sec` | 0 | Per-child wall-clock cap (R-02), shared by ancillary children and detached durable task attempts. `0` disables the default cap, preserving the historical unbounded behavior and avoiding surprise kills of long autonomous review loops. Set a positive value to SIGTERM then SIGKILL children past their deadline. Min 0. |
| `child_verb_timeouts` | `{answer-digest: 3600}` | Per-verb overrides of `child_timeout_sec`, e.g. `{review: 10800, brainstorm: 1800}`. Each value is an integer ≥ 0 (0 disables that verb's cap). Fresh durable attempts resolve this map from current global daemon config. |
| `child_kill_grace_sec` | 30 | SIGTERM→SIGKILL escalation window for a timed-out child or post-leader durable-attempt drain. Min 0 (0 = immediate escalation in the attempt wrapper; ancillary children escalate on the next timeout tick). |
| `log_file` | `~/Dev/hive/logs/daemon.log` | Structured-log destination. |
| `log_max_bytes` | 10485760 | 10 MB rotation threshold. |
| `log_max_files` | 5 | 5 × 10 MB = 50 MB log budget. |

## Retry policy on child exit

| Exit | Constant | Action |
|------|----------|--------|
| 0 | `SUCCESS` | No cooldown; daily counter +1 and the next stage may dispatch immediately |
| 3 | `TASK_IN_ERROR` | No immediate controller retry. The durable failure marker remains visible; `ERROR` / `REVIEW_ERROR` enter the shared cooldown and coordinator lifecycle, while manual recovery markers remain parked. |
| 4 | `WRONG_STAGE` | 60s protective backoff (race or classifier bug) |
| 64 | `USAGE` | Quarantine `(project, slug)` for daemon lifetime |
| 70 / 1 | `SOFTWARE` / `GENERIC` | Transient: 60→120→300 s backoff, then quarantine |
| 75 | `TEMPFAIL` | Refund the daily slot. Ancillary children may retry next tick; durable task attempts retain a scheduler-owned point-indexed hold for `transient_retry_backoff_sec` before a fresh request is admitted. |
| 78 | `CONFIG` | Drop the entire project from active dispatch until daemon restart |

## Structured log

`~/Dev/hive/logs/daemon.log` is one JSON document per line:

```json
{"ts":"2026-05-06T12:00:00Z","schema":"hive-daemon-log","schema_version":1,"event":"dispatched","pid":12345,"project":"writero","slug":"fix-x","stage":"6-review","command":"hive run fix-x --json","dry_run":false}
```

Closed `event` enum (`Hive::Daemon::Logger::EVENTS`). Adding an event
without updating the enum raises `ArgumentError` at the call site so
new events are caught rather than logged silently. CI scans every literal
`.event(:symbol)` producer under `lib/hive/daemon/` and requires the symbol in
the closed enum; permissive test loggers therefore cannot hide a production
failure-path mismatch. Merge-archive completion, module runtime, stalled
markerless rows, dispatch-sequence promotion failures, and task-id backfill
outcomes all use registered event names.

## Operational notes

- **Day-2 guide is at [[operating]]** — service setup (`hive daemon
  install`), project enrollment (`hive daemon enable PROJECT|--all`),
  autostart on Linux (systemd-user) and macOS (launchd), dry-run
  shakedown, and troubleshooting.
- **First-time rollout:** `hive daemon start --dry-run` for ~24 hours
  before going live. Inspect `daemon.log` to validate dispatch
  decisions. Then `hive daemon stop` and re-start without `--dry-run`.
- **Cost runaway response:** `hive daemon stop` is one command. To
  exclude a single project mid-flight: `hive daemon disable PROJECT`
  (the next tick honours it automatically). In-flight children
  continue to completion.
- **macOS / Linux:** `Process.daemon` works on both; the daemon does
  not require `systemd`. Sample autostart units ship at
  `examples/systemd/hive-daemon.service` (Linux) and
  `examples/launchd/hive-daemon.plist` (macOS).
- **Pausing a single task:** edit the state file to remove the terminal
  marker (e.g., delete `<!-- EXECUTE_COMPLETE -->`) so the row no
  longer classifies as advance-ready. Daemon will skip until you write
  the marker back.

## Exit codes

| Subcommand | Code | Condition |
|------------|------|-----------|
| `start`    | 0    | (foreground daemon exited cleanly) |
| `start`    | 75   | Another daemon already running (TEMPFAIL) |
| `stop`     | 0    | Always (idempotent) |
| `status`   | 0    | Daemon is running |
| `status`   | 1    | Daemon is not running |
| `reload`   | 0    | SIGHUP sent successfully |
| `reload`   | 1    | Daemon is not running |
| `tail`     | 0    | Stream ended via Ctrl-C |
| `tail`     | 1    | Log file does not exist |
| `queue list` / `queue prune` | 0 | Always (lists / prunes; empty is still success) |
| `queue show <id>` | 0 | Request found |
| `queue show <id>` | 1 | Request not found (GENERIC) |
| `queue` (any)     | 64 | Unknown queue action, or `show` with a missing REQUEST_ID (USAGE) |
| `queue` (any)     | 70 | Internal IO/parse error (SOFTWARE) — wrapped so the exit code matches the `--json` envelope's `error_kind:"internal"` (#262) |
| (any)      | 64   | Unknown subcommand |

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/status]] · [[commands/approve]]
- [[modules/daemon]] · [[modules/plan_review]]
- [[decisions]] (ADR-024)
- [[architecture]]
