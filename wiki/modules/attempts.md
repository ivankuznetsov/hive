---
title: Durable task attempts
type: module
source: lib/hive/attempts/
created: 2026-07-16
updated: 2026-08-27
tags: [attempts, ownership, leases, daemon, recovery, bounded-storage, diagnostics]
---

**TLDR**: Every accepted task-stage launch has one immutable attempt ID and
one versioned JSON lease/receipt under `$HIVE_HOME/attempts/v4/`. A detached
supervisor wrapper—not the CLI, bot, web process, or daemon—owns the worker
group, heartbeat, framed output, exit status, and terminal receipt. The daemon
reconciles and applies policy over the bounded hot set; it does not own or reap
task agents.

## Module map

| Module | Responsibility |
|--------|----------------|
| `API` | Provide Hive commands, bot delivery, daemon recovery, and module-hook delivery with the stable admission operations `dispatch`, `dispatch_request`, `dispatch_successor`, and `dispatch_module_hook`, while keeping one injected store shared by its foreground and daemon adapters. |
| `Contracts` | Define the public `ClientResult`, `DispatchResult`, and `UnsupportedDetachment` values independently of the internal client, dispatcher, and launcher implementations. |
| `Record`, `Store` | Read and write schema-v4 records in the physical v4 layout, scan only hot records, point-fetch hot or permanent proof, perform locked guarded transitions with atomic write/fsync/rename persistence, and copy nested record/checkpoint/receipt values through `Hive::StringifyKeys`. `Store::ProjectionReader` is a read-only scan-scoped view that caches each immutable projection binding once without making the long-lived runtime store stale. The default store opens only v4 and contains no migration trigger or legacy-layout monitor. |
| `Capability`, `Context` | Generate one-time launch authority, authenticate the exact worker process/task/stage, revalidate generation at the mutation boundary, expose the immutable admitted route, and provide one inherited bounded diagnostic writer after transport variables are scrubbed. |
| `Generation` | Bind stable task identity, intended stage, and a workflow progress token into the semantic ownership key. |
| `Dispatcher` | Resolve receipt replay, live duplicate attachment, durable transient-contention pacing, loss deferral, capacity, deterministic explicit-provider routing, fresh admission, and explicit successors. |
| `DetachedLauncher` | Reject unsupported platforms before handoff, create a POSIX session, and start the private supervisor route. |
| `Supervisor` | Claim, first-heartbeat, spawn the existing Hive command, heartbeat, frame output, enforce timeout/cancellation, validate one child diagnostic frame, bind its exact private log reference, and terminalize only after appending the diagnostic output reference. |
| `Client` | Tail frames read-only and replay a terminal result. It performs one final drain after observing a terminal or lost record so frames published during the decisive record fetch are not dropped. Interrupt means detach; it never signals the owner group. |
| `CommandDispatch` | Give `hive run` and workflow stage commands one attach-result policy: shared durable dispatch, lost-attempt translation, receipt exit propagation, and single-document JSON fallback when a failed worker emitted no stdout. |
| `Reconciler`, `ProcessIdentity` | Adopt without `wait2`, detect PID/start/session/group mismatch, preserve suspects, expire launches, normalize loss, and publish current hot counts beside cached storage-maintenance health without scanning historical proof or cold logs. |
| `DirtyStateCapture`, `LostOutcomeStore` | Inventory partial git/untracked/binary work without mutation and make cleanup/successor policy restart-idempotent. |

## Admission API boundary

`Hive::Attempts::API` is the consumer-facing boundary for admission. Hive is
its first and primary consumer: durable CLI commands call `dispatch`, bot and
other local producers call the same operation non-interactively, and daemon
queue delivery or loss recovery call `dispatch_request` and
`dispatch_successor`; the module daemon calls `dispatch_module_hook` through
the same facade. An injected `Store` is shared by both adapter paths.
Filesystem locks, atomic rename, and fsync keep the protocol host-local
without adding an event bus.

`Entrypoint` and `ConfiguredDispatcher` are internal adapters behind that
boundary. `Dispatcher`, `DetachedLauncher`, `Client`, and the persistence
classes remain implementation collaborators rather than construction points
for new admission consumers. `Contracts` owns the returned `DispatchResult`
and `ClientResult` values plus the public `UnsupportedDetachment` admission
error, so consumers do not load those internal adapters merely to interpret an
outcome.

This boundary does not split Attempts into another repository, process, or gem.
It creates an in-monorepo seam that Hive can exercise first; a separately
published package remains a later response to demonstrated non-Hive demand,
not a requirement of the module design.

Task-projection cache validation and journal replay use
`Store#fetch_projection_binding`. Hot records still receive full schema
validation because their lifecycle fields can
change. Immutable permanent proofs take a narrower validated read of the exact
identity, generation, state, outcome, lease, and lineage fields consumed by the
projection. New permanent proofs publish that subset as a separate immutable
point-addressed sidecar; older proofs fall back to the full document and can be
backfilled without changing it. Full `Store#fetch` continues to validate
receipts, diagnostics, and every output reference for consumers that use those
domains. This prevents a status scan from repeatedly reading or walking
cumulative inherited-output arrays while preserving fail-closed binding
validation.

The component catalog keeps this admission slice as a guarded reference
`candidate`. Its facade, result contracts, focused clean-process load, and
exact internal-construction sites are enforced now. U8 removed the former
Attempts/WorkLedger catalog dependency and reciprocal-source exception:
task-journal generation reads and `TaskProjection::Store` are Hive adapters,
not source owned by the policy-light WorkLedger component. Attempts remains a
candidate because this guarded reference does not turn the full durable-attempt
lifecycle into a supported component API:
reconciliation, supervision, capacity, loss processing, cancellation, export,
and raw store operations remain internal. The supported facade still has only
`dispatch`, `dispatch_request`, `dispatch_successor`, and the module-specific
`dispatch_module_hook`; its clean-process
load brings in the result contracts without commands, stages, web code, or
other candidate entry points.

Hive still has narrow, cataloged internal construction sites: the daemon
composition root wires reconciliation and loss processing, the private
supervisor argv adapter starts the owner wrapper, module inspection and
dry-run preview open the canonical store read-only, the `hive status` scan
hoists one read-only store for the whole scan, and compatibility adapters
plus `TaskClosure`'s active-attempt verification do the same. These sites are
not alternate admission producers. The component-boundary test pins each
file/constant pair and rejects the same construction from any newly listed
file even while Attempts remains a candidate. Authorization is file-granular,
so it does not distinguish a second call site inside an already authorized
composition root.

## Storage and identity

Attempt schema v4 retains the generalized execution subject and adds a required
immutable routing union. Task attempts use an
explicit `task_stage` subject, while module hook attempts use a first-class
`module_hook` subject containing the project, module, hook, event/decision
identity, generation, configuration, and grant digests. Module hooks do not
fabricate task folders merely to reuse the supervisor. A legacy attempt stores
exactly `{mode: legacy}`. An explicitly routed attempt stores its frozen policy
digest, decision, provider account, adapter/profile, launch-binding identity,
model/effort, enclosing circuit generation vector, and probe bindings. Runtime
readers accept v4 only. The one-off recovery migration converts valid schema-v3
records and permanent proofs to v4 legacy mode while moving the physical v3
tree to v4; malformed hot bytes remain exact capacity reservations, while an
unreadable immutable proof aborts the cutover. Its exact-parity gate rebuilds
same-day admission accounting from both the bounded hot set and permanent
proofs, because finalization may promote a terminal attempt before an
interrupted cutover resumes. Only `hive migrate` and `hive migrate --all` invoke
that migration. Store construction, status, daemon startup, and bot startup do
not inspect, convert, or monitor old state; operators run the command before
starting current runtime processes.

Both subjects share the same CAS record store, leases, capabilities,
heartbeats, detached ownership, bounded retry accounting, receipts, output
references, reconciliation, and capacity accounting. A module hook retry stays
attached to its admitted occurrence; disabling or uninstalling the module
closes pending retry authority instead of replaying it on re-enable. A retry
deferred by capacity or handoff recovery waits one hour before another
admission attempt, preventing daemon-tick spin while preserving the occurrence.
The run ledger retains the pending reason and intended charge for redacted
status projection.
The private `hive __module-hook` worker also requires an installed,
authenticated attempt context; transport environment is deliberately scrubbed
before routing. Its subject is validated directly against module/hook,
project, and event identity rather than being misresolved as a task. Lifecycle
mutation and hook admission share the module-store lock, and a detached-launch
handoff failure remains a bounded retrying run without advancing the hook
cursor. If the process is admitted before its decision receipt is appended,
the next dispatch reconstructs the original launch receipt from the exact
attempt subject.

```text
$HIVE_HOME/attempts/v4/
├── records/<attempt-id>.json              # live and finalization-pending hot set
├── proof/...                              # permanent point-addressed receipts
├── decision-indexes/...                   # semantic/request/latest-terminal/successor and routed-decision indexes
├── pending-finalization/...               # consumer acknowledgements
├── logs/<attempt-id>.frames               # active raw stream
├── cold-logs/<digest-shard>/...           # finalized raw stream awaiting expiry
├── log-state/...                          # archive/expiry state
├── maintenance/...                        # one cached health/status cell
├── routing-policies/v1/...                # point-addressed generation policy snapshots
├── outputs/<attempt-id>/...
└── generation-locks/{admission.lock,<sha256>.lock}
```

`Store#scan` enumerates `records/` only. It never walks `proof/`, decision
indexes, or cold logs. `Store#fetch` first checks the hot record and then uses a
point lookup in permanent proof, so historical consumers do not force a global
history scan. Final records leave the hot set only after permanent proof,
decision indexes, and every required consumer acknowledgement are durable.
Raw logs move into digest-sharded cold storage at promotion and expire when the
task is archived or three days after the attempt ended, whichever comes first.
An hourly persisted cursor examines at most 512 cold logs per pass, so archive
history cannot turn maintenance into a scheduler-sized directory walk;
canonical proof and referenced output artifacts are not deleted by raw-log
retention.

Operational status reads one bounded maintenance cell plus counts already
produced by the current hot reconciliation. It reports only the latest
migration and maintenance deltas (`promoted`, `deleted`, and `cold_examined`),
not lifetime totals, and a failed write/read becomes one concise degraded
warning. Status never scans proof or cold-log history.

The current explicit-routing decision cell is the one bounded exception for
operator inspection. It retains project, task generation, strict subject,
optional admitted attempt ID, and the complete sanitized route decision. The
selected form therefore identifies its attempt, while first no-route/capacity
forms remain explainable despite creating no attempt. `hive circuits` may
enumerate at most the fixed projection bound; admission, recovery, and
reconciliation continue to use point-addressed decision reads and writes.

The record carries attempt/request/predecessor IDs, task and generation
identity, the exact admitted worker argv, a SHA-256 digest of a random launch
capability, adapter/profile provider, immutable routing identity, retry charge,
revisions, wrapper/worker fingerprints,
deadlines, checkpoint, integrity references, diagnostics, and loss or receipt
fields. The capability itself is never persisted. Large payloads remain
owner-private referenced files with canonical relative path, byte size, and
SHA-256.

Failed Patrol Fix attempts add exactly one
`outputs/<attempt-id>/patrol-fix-attempt-diagnostic.v1.json`. The child may
send one bounded schema-valid frame; EOF, duplicate, malformed, and oversized
frames are closed transport states rather than trusted evidence. The
supervisor revalidates identity and scans the complete document for secret
patterns, injects the exact
per-spawn log reference, and synthesizes a minimal typed terminal diagnostic
from authoritative exit, timeout, cancellation, and signal state whenever a
failed Patrol attempt has no usable frame. Secret-bearing metadata invalidates
the child frame rather than being persisted. A trusted provider-evidence signal
overrides child attribution and supplies the provider-owned failure class on
both finalized and synthesized diagnostics. The supervisor resolves the task's
current workflow controller before writing the artifact; overlapping Bench and
Patrol stage directory names are not workflow identity. Output reads used by projections
share the `OutputReference` custody primitive: they open the validated lexical
path with `O_NOFOLLOW`, bound bytes, and verify the receipt size and SHA-256
from the same descriptor. Raw log bytes are never a status fallback.

For an explicit pool, admission freezes the task-generation policy before the
first decision, including no-route and provider-capacity results. Under the
fixed admission -> task-generation -> provider-health lock order, it derives
account usage from live durable attempts, obtains a pure ordered routing
decision, and revalidates every enclosing circuit generation before creating
the attempt. Routed attempts count their exact account. A legacy attempt counts
only toward the single configured `default` account to which its existing
adapter maps unambiguously; legacy admission itself never consults that cap.
All-compatible provider saturation creates no attempt or probe and returns a
scheduler-owned observation.

Opening and reconciling provider health are both inside the same fail-closed
admission boundary. If the health store cannot be constructed because its
state is unavailable or its managed directory is unsafe, admission evaluates
every candidate as `health_state_unavailable`, persists the operator-owned
no-route decision, and starts no attempt. Legacy admission still returns
before constructing provider health.

When a selected route is half-open at one or both scopes, admission persists a
health intent, creates the launching attempt with every resulting probe
binding, finalizes each claim, and only then launches. Restart reconciliation
accepts an intent only when the exact durable attempt contains the matching
bindings. Closed-route admission uses the same generation-vector CAS without
creating a probe. A concurrent circuit mutation triggers bounded deterministic
re-selection rather than committing stale health.

The configured store root remains the trusted anchor and may itself resolve
through an operator-selected link. Its managed children may not: creation and
every later access
revalidate that each child is a real directory, not a symlink, and that its
resolved path remains below the trusted root before chmod, read, lock, or
write. Record and lock leaves use no-follow checks; attempt stream readers
ignore symlink leaves and writers refuse them. A stream read also treats a
non-directory or symlink-loop parent as unavailable instead of raising through
status or TUI replay. Concurrent creation of the same per-attempt output
directory revalidates the winning entry before use.
Lost-outcome and dirty-state directories receive the same containment check.
Corrupt or replacement links therefore fail closed and never redirect attempt
state or permission changes outside `$HIVE_HOME/attempts/v4`.
The descriptor adapter selects Linux `O_DIRECTORY` by CPU architecture:
x86_64 uses `0200000`, while aarch64 uses `040000`. This keeps the same
fail-closed managed-directory custody on both supported Linux architectures.

Record construction/readers and store transitions all use the same
non-mutating `Hive::StringifyKeys` transform as the task journal and projection.
It recursively copies hashes/arrays and stringifies keys while leaving scalar
values unchanged, preserving the former `Record.deep_copy` contract without a
second normalization implementation.

Task generation owns semantic success while request ID owns delivery
idempotency. Its progress token hashes both the stage artifact and this task's
deterministic dependency-admission verdict. Replaying the same request returns
that request's original terminal receipt, including a failure. A different
request against an unchanged generation may start a fresh attempt after a
failed/cancelled receipt; only a successful terminal receipt remains the
semantic owner for later requests. Exit `75 (TEMPFAIL)` is the exception: it
means Hive lost a transient scheduler or lock race, not that the agent failed.
The latest terminal decision index retains that generation's exact attempt ID
after finalization moves its record to permanent proof. A different request is
therefore scheduler-deferred until `transient_retry_backoff_sec` has elapsed
from the receipt, without scanning history or running a retry watcher. The
daily attempt charge remains refunded. A later terminal outcome replaces the
point index, so an old TEMPFAIL cannot pace the generation forever.

A live owner is attachable only when its
task generation matches the new request. When the same task and stage are live
under a different generation, admission returns `deferred(in_flight)` instead:
the request stays queued until the old owner exits, then runs its distinct
command. This prevents a queued plan rerun from being silently attached to an
older `plan-review-run` merely because both operate at `3-plan`. A dependency wait that later becomes clear
advances generation instead of replaying the stale exit-75 receipt. A lost
attempt blocks admission only until its explicit successor exists, so a
terminally failed successor cannot leave the generation trapped behind a
resolved ancestor loss. A loss successor has a new attempt ID but inherits
generation, predecessor, outputs, worktree/branch, and an incremented retry
charge; healing is therefore a separate ledger successor admission and never
projects a recovery marker. An omitted or empty successor-output override inherits the
predecessor's complete output set; only a non-empty explicit override replaces
it.

`plan-review-run` also binds the byte-exact `plan-review/current.json`
projection into its progress token. Plan review is a multi-step state machine:
it can move from revision to verification or install a bounded recovery reset
without changing `plan.md` or its completion marker. An unchanged projection
still replays the successful orchestration attempt, while a changed projection
advances generation so the daemon can run the next review step instead of
replaying the earlier success forever.

Patrol Fix task generations likewise bind the validated append-only
`patrol-fix-receipts.jsonl` projection in addition to the immutable task
manifest. Each controller stage records its outcome as a receipt before the
separate advance action moves the task. An unchanged journal still replays the
successful controller attempt, while a newly appended receipt advances
generation so the daemon can admit the corresponding stage transition.
Malformed journals contribute a stable unreadable-owner token and remain
fail-closed in the Patrol Fix projection. Ordinary dispatch, worker-side
generation fencing, and recovery generation resolution all use this same
task-owned token; they cannot partition one Patrol task into separate
generation namespaces.

A terminal explicit attempt with a trusted provider-evidence receipt is also a
valid, narrowly scoped successor predecessor. `RecoveryCoordinator` alone puts
that immutable predecessor ID on the v5 recovery delivery after provider
health acknowledges the receipt. Admission then skips terminal replay for
that explicit successor request, preserves the predecessor generation and
frozen routing policy, and records the new attempt in the ordinary successor
index. Arbitrary terminal failures and untrusted or legacy failures cannot use
this path.

Condition projection adds an explicit numeric `task_input_epoch` to attempt
records/context while retaining the prerequisite's opaque ownership generation
as `ownership_generation`. `hive-attempt` v4 remains the sole runtime record
shape. `Hive::Recovery::Migration` performs the physical v3-to-v4 cutover and
also accepts a still-supported v2 source. It refuses live writers and any
attempt whose owner may still be active. Under the quiesced writer locks it
reconciles only expired pre-heartbeat launches and running attempts whose
recorded process identity is definitively missing or mismatched, preserving
them as ordinary lost records instead of blocking the cutover. It then renames
the validated tree, converts valid v3 records/proofs, publishes old-
binary fences, verifies the converted corpus and decision parity, promotes
historical finals, and writes the v6 recovery receipt only after its durable
checkpoint reaches `complete`. Runtime code opens v4 only; there is no reverse
migration and no dual reader. A material competing-root collision, obsolete v1 tree,
unsupported record schema, symlink, ownership mismatch, or changed corpus fails
closed without choosing an authority. Every
condition event must name a durable attempt whose task/stage ownership matches
the record. Retry and adoption reuse the numeric epoch when accepted inputs
are unchanged.

## Task workspace attempt/session projection

The task workspace never calls `Store#scan`. Dispatcher admission writes an
attempt-bound task-journal activity after the durable record exists and before
worker handoff. Read-time discovery begins with that task-local binding (or the
legacy `TaskProjection.identity.attempt_id`) and follows only exact predecessor
IDs through `Store#fetch`, bounded to 100 seed IDs, 32 predecessors, and 512
KiB. Only the canonical projection binding can mark an attempt current;
overlapping live but unbound records are conflicting evidence.

Every actual child spawn receives a separate session/correlation ID beneath
the attempt. Durable start/finish observations preserve role, requested
provider/model/effort, provider-reported actual model when available, health,
outcome, timeout, typed guards, resource observations, and usage. Missing
runtime values remain unavailable and browser/Turbo connection state is never
used as agent health. This child-session identity is distinct from the POSIX
session/process-group ownership fields on the supervisor attempt record.

Attempt admission and other `activity_recorded` rows are evidence within the
numeric input epoch selected before launch; `GenerationTracker` excludes them
when deciding whether inputs advanced. A retry may reconcile a prior pending
domain-operation receipt only after revalidating that receipt's historical
attempt/task/stage/epoch/ownership binding against `Attempts::Store`. Provider
execution is enclosed by lazy artifact custody after `session_started`; a safe
validation/restore precedes context promotion and `session_finished`, so
controller journal appends neither trip nor bypass protected-file custody.

See [[modules/task_workspace]] and [[token-usage]].

## State protocol

```text
launching/unclaimed --capability + claim CAS--> launching/claimed
launching/claimed --first heartbeat CAS--> running
running --receipt CAS--> terminal(succeeded|failed|cancelled)
launching|running --expiry/reconciliation CAS--> lost
```

`terminal` and `lost` cannot become live again. Each mutation compares attempt
ID, generation, observed state, lease version, and active deadline while
holding the generation lock. Configurable defaults are heartbeat 5s, stale
30s, launch timeout 30s, and first-heartbeat timeout 30s. The daemon resolves
those timers from the admitted task's project on every initial or successor
dispatch. The wrapper must win first heartbeat before it may spawn the stage
worker.

## Admission and execution

Public `hive run` and workflow verbs enter `Attempts::API`, which delegates to
its foreground adapter. Bot/web v5 requests, daemon queue/auto-advance, and
recovery use the same API boundary. Runtime queue readers accept v5 only; the
same one-off migration upgrades pending v1-v4 files before they are opened. The
launcher double-forks into a distinct session. The dispatcher gives the wrapper
a one-time random capability through an inherited pipe; the private
`__attempt-supervise` route accepts no worker command argv and can claim only
by proving that capability against the immutable record digest. The supervisor
then executes the record's exact argv.
Admission is reported accepted after the launcher confirms the claim or
reports the authenticated wrapper in its durable `launching` state. A
false/malformed handoff or launcher exception marks the unclaimed reservation
`lost` and returns a retryable deferral; if the wrapper won the claim race, the
dispatcher re-reads and adopts it instead of creating an overlapping owner.

An explicit-policy initial admission that returns no route has no attempt to
attach. The foreground adapter therefore hands that markerless result directly
to `RecoveryCoordinator`, which creates the same single pending request and
retry charge used by daemon recovery. Interactive callers receive a concise
deferred error containing the recovery receipt; bot delivery leaves the queued
request pending instead of dereferencing a nonexistent attempt or deleting its
only retry authority.

Capacity scan and reservation creation take the shared admission lock before
the generation lock. That fixed order makes the limit decision atomic across
different tasks and projects, rather than only among duplicates of one
generation.

For Hive workers, startup is held behind a second inherited-FD gate. The
supervisor first persists the worker PID, start fingerprint, session, and
process group, then releases the gate. `Context` installs only when the record
is running and its capability, exact process identity, argv, resolved task,
and intended stage all match. `hive run` and generic `hive approve` bind that
stage to the task's current descriptor position; stage-specific workflow verbs
bind it to their registered target. Immediately before the first task mutation,
the worker recomputes its generation while the task lock is held and rejects a
stale admission; this closes the dispatch-to-execution window for task or
dependency changes. It immediately deletes every inherited
`HIVE_ATTEMPT_*` key, so agent processes and nested Hive commands cannot inherit
the admission bypass. The attempt transport cannot supply a dedicated store
override, and production exposes neither public context construction nor a
`Context.with` override. The authenticated context remains only in the worker
process. An attached client records whether any stdout frame was replayed.
`Hive::Attempts::CommandDispatch` applies that result identically for `hive
run` and workflow verbs: a non-zero terminal result with no worker stdout is
routed through the owning command's normal versioned JSON error envelope
instead of returning an empty document; a worker-emitted document is never
duplicated; lost attempts without output become the command's typed concurrent
run error; and every other non-zero receipt preserves its exit status.

This is an application ownership boundary, not privilege separation. Hive's
configured global attempt store, its `HIVE_HOME`/`XDG_STATE_HOME`/`HOME`
process configuration, and the same-UID Ruby process are trusted; code with
arbitrary environment, write, or monkeypatch access can bypass application APIs.
Treating provider agents as hostile at that OS boundary requires a separate
broker identity and protected signing/storage authority (tracked in
[[gaps]]).

Legacy task locks and markers gain optional `attempt_id`, opaque
`task_generation`/`ownership_generation`, and numeric `task_input_epoch`
projections inside the worker. They remain readable
compatibility/evidence records, not ownership truth. The internal log is
append-only sequenced JSON frames with timestamp, channel, and base64 bytes;
the CLI still presents ordinary stdout/stderr and the receipt exit status.

## Explicit route evidence and finalization

Supervisor gives an authenticated explicit Hive worker one additional
write-only descriptor. `Attempts::Context` installs it only after the ordinary
claim capability, worker argv, task binding, process identity, and released
gate all match, then marks it close-on-exec before any provider child starts.
The channel accepts at most one bounded strict safe signal. Empty, malformed,
oversized, duplicate, broken-pipe, and wrong-route values become no signal;
stdout and stderr are never parsed by Supervisor as provider evidence.

After the worker exits, Supervisor binds a valid safe signal to the protected
attempt log reference, derives its fingerprint only from canonical safe
fields, forces a failed terminal outcome, and stores it in the immutable v1
terminal receipt. Legacy workers receive no evidence descriptor and retain
their existing invocation, marker, and `limits_reached` behavior.

Explicit terminal and resolved-loss records add `provider_health` to the
pending-finalization consumer ledger. The receipt remains hot and cannot be
archived until `ProviderHealth::AttemptObserver` has idempotently applied or
rejected the observation and the acknowledgement is durable. Reconciliation
performs that observation before downstream condition/recovery publication;
lost probe ownership is therefore reopened before a successor can use the
route.

## Reconciliation and capacity

At daemon startup and before each healer/admission tick, fresh heartbeat plus
matching PID/start fingerprint is adopted. Stale-but-matching or unverifiable
identity is suspect and still reserves capacity. Missing/reused identity can
win the one-way loss CAS. Adoption never calls `wait2` because wrappers are not
children of a restarted daemon.

Launching, running/suspect, and confirmed-live or unsafe-cleanup lost leases
are authoritative capacity. A lost lease stops reserving only after cleanup
records the worker as absent, terminated, or never identified. Status rows
are a deduplicated legacy fallback only when no durable identity exists.
Evidence order is terminal receipt, matching current-generation marker, then
git inventory; commits or a clean worktree never prove stage success.

## Definitive loss

A live worker group is signalled only when start fingerprint and session/group
membership still match. Drift remains pending and is rechecked; Hive never
signals an unverifiable process group. Once the worker is absent,
`DirtyStateCapture` records HEAD, porcelain-v2 status, binary patches, and
hashed untracked metadata without stash/reset/checkout/clean/add/commit.

Attempt loss does not project an `ERROR reason=attempt_lost` compatibility
marker. The attempt ledger and `LostOutcomeStore` are the sole durable loss
lifecycle: `StaleAgentHealer#heal_attempt_losses` verifies orphan cleanup,
captures dirty state, and asks the shared attempt dispatcher to admit a
same-generation successor. Conditions and status may expose `attempt_lost` as
read-only health, but marker recovery does not interpret attempt lineage.

`retry_charge` remains durable lineage/accounting evidence but is not an
exhaustion budget. Unsafe cleanup, temporarily missing task lookup, and lost
successors remain retryable until the process becomes safely absent or a
successor is admitted. Unsafe
orphan-cleanup inspection itself is paced by the shared cooldown, so one
unreaped process cannot trigger expensive cleanup on every daemon tick.
Successor dispatch attempts use the same persisted cooldown; a deferred
admission records `last_retry_at` so daemon restarts cannot collapse the delay
into a per-tick loop. Global and per-project automatic-retry gates apply to
this lease-backed path exactly as they do to marker errors. A successor
replays the immutable admitted workflow
argv and flags; if the command already moved the task, only its locator is
retargeted and a satisfied `--from` assertion is removed. Queue claims follow
an admitted successor and later complete from its receipt. If the daemon
crashes after admission but before stamping the queue claim, restart repairs
correlation by the immutable request ID before deciding whether the claim is
live.

If a successor itself terminates with a normal recoverable failure marker, that
fresh marker enters the ordinary `RecoveryCoordinator` lifecycle. It is not a
special attempt-loss branch.

## Tests

Focused tests are under `test/unit/attempts/` and
`test/unit/daemon/attempt_loss_healer_test.rb`. The YAML subprocess replay
`durable_attempt_1849_replay.yml` creates three commits, kills the temporary
CLI group, verifies the execute lease remains in the hot scan without a daemon,
then point-fetches the same ID from hot or permanent proof and accepts
completion only from its wrapper receipt.

## Backlinks

- [[architecture]] · [[state-model]] · [[commands/run]] · [[modules/daemon]] · [[testing]]
