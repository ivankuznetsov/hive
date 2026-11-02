---
title: Hive::Patrol
type: module
source: lib/hive/patrol/, lib/hive/refactor_patrol/, lib/hive/patrol_fix/, script/migrate_patrol_findings.rb
created: 2026-05-28
updated: 2026-11-02
tags: [module, patrol, architecture, workflow]
---

**TLDR**: Ordinary Patrol and Architecture Patrol are discovery systems. They
write their own native findings/jobs and reserve accepted work directly in the
shared `patrol-fix` `AdmissionStore`. They do not fix code, open issues, or
publish pull requests. There is no Patrol module cutover, shadow comparison,
occurrence journal, effect delivery layer, or runtime migration subsystem.
Historical ordinary findings and accepted Architecture Patrol dispositions can
be imported once with `script/migrate_patrol_findings.rb`.

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

Merged-PR intake stores only repository paths, file statuses, and rename
origins. GitHub patch bodies are neither an admission signal nor an immutable
input: semantic classification uses merge metadata and the changed-path
inventory, while discovery analyzes the exact pinned worktree. Older v3
records that contain patch bodies remain readable, but new records omit them
and no patch-size threshold can block cursor progress. Replay compares legacy
and current snapshots after removing only the obsolete patch field; it does
not rewrite or migrate the old record. True snapshot conflicts enter the
normal reconciler backoff instead of hot-spinning one ingest index.

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
discovery have separate per-project, per-engine daily launch allowances. Each
allowance is derived from unique `patrol_discovery_launch` reservations in
`token_usage` for the current UTC date. One immediate transaction recognizes an
existing session reservation before counting and inserting a new zero-token
row, so retries are idempotent and concurrent daemon processes cannot
oversubscribe the limit. The next UTC date resets naturally. Provider failures
do not create lane holds or other durable usability state.

The Patrol arbiter alternates ready ordinary and architecture candidates under
`daemon.max_concurrent_patrol_scans`. Candidate discovery is read-only;
reservation revalidates current project registration/configuration and acquires
the native store claim immediately before dispatch.

Patrol Fix admission scheduling reads one compact pending index per project.
The index maps each active occurrence to either immediate eligibility or its
next decision-expiry/retry time, so `pending(limit:)` opens at most twice the
selected record limit when crash repair is needed instead of parsing the
complete admission inventory. An uncontended clean tick still opens only the
records it returns. Authoritative records remain the source of truth. Normal
state transitions maintain the index under the inventory lock; selected stale
entries left by an interrupted cross-file transition are repaired while the
same bounded tick continues to ready work. A contended scheduler read skips one
tick rather than blocking the daemon. Existing unindexed stores must be
initialized explicitly with `hive migrate`; daemon ticks never perform a full
index rebuild or run a migration watcher.

Task materialization revalidates the semantic candidate set immediately before
binding. If that set changed, it resets the admission to `pending` and the
scheduler treats the resulting stale-decision signal as fresh semantic work;
it never converts that intentional reset into a materialization retry. Genuine
I/O or task-store failures continue through the bounded `retry_wait` path.
Existing-task manifest and publication-receipt writes, their scoped commit,
and any failure restoration plus index reset remain inside one project commit
lock, so rollback staging cannot interleave with another hive-state writer.

Architecture discovery claims retain PID, process-start-time, process-group,
lease, heartbeat, owner, and generation. A stale generation cannot checkpoint.
A new daemon may reclaim a dead exact process; live or unverifiable ownership
remains fenced.

## Patrol Fix and publication

For the retained uncertainty and historical evidence, see [Unified Patrol Fix live execution](#unified-patrol-fix-live-execution).

Patrol Fix owns the repair workflow:

1. Inbox re-investigates the current source and makes the semantic admission
   decision.
2. Fix creates or recovers one exact local worktree generation.
3. Validate runs only configured or structured validation commands in a
   disposable detached checkout pinned to the fix receipt's exact HEAD.
4. Review records an independent route decision.
5. Publish uses `Hive::GithubPublication`.

The task manifest is immutable during each controller stage. Stage outcomes
are appended to `patrol-fix-receipts.jsonl`, and that validated receipt
projection participates in durable attempt generation. The successful stage
run therefore remains idempotent while its journal is unchanged, but appending
the outcome receipt makes the following advance action a new semantic attempt
instead of replaying the stage run forever. The worker mutation fence and
recovery coordinator resolve that same receipt-aware identity before accepting
side effects or retrying the task.

Ordinary Patrol Fix completion requires the current publication receipt. The
separate evidence-closure protocol may instead retire a task whose change was
already delivered through verified external evidence. Its `closure.json`
authorizes only the workflow-terminal move, remains the terminal projection's
completion authority, and does not fabricate a publication receipt or dispatch
a runner for the controller-owned inert `6-done` stage.

The Fix stage alone owns the authoritative patch checkout. Validate proves that
checkout is clean and at the fix receipt's exact HEAD both before and after the
run, but executes operator commands in a separate root-confined detached
materialization. Formatter and test writes are force-discarded with the
disposable tree, including when the validator raises. Cleanup failure never
masks that validator outcome or discards a completed validation result: Hive
warns with the retained checkout path for operator recovery. A concurrent
same-user write to the authoritative checkout cannot be prevented at this
boundary; the post-run custody check detects it and fails closed without
appending a validation receipt. Review and Publish continue to inspect the
authoritative checkout read-only through `WorktreeSnapshot`.

The disposable checkout starts from tracked files at the receipt-bound commit.
Hive never copies or symlinks ignored dependencies, secrets, caches, or local
tool state from the authoritative checkout. Operator-configured commands and
agent-selected structured commands must therefore include any bootstrap they
need inline, such as `npm ci && npm test`. The Fix prompt states this constraint
before the agent selects commands, so validation cannot silently inherit a warm
or secret-bearing development checkout.

Review rework resolves the exact prior Review decision referenced by the
current-generation reopen receipt and supplies that rationale and evidence to
Fix inside the same untrusted prompt boundary as the finding. Before appending
the new Fix receipt, Hive compares its diff digest and structured validation
commands with the prior Fix receipt referenced by Review. If both are unchanged,
the run fails without a new receipt and preserves the owned worktree for another
attempt. A validation-plan-only correction remains valid even when the patch is
unchanged.

Inbox and review use the independent `patrol.agent` identity and the
`models.patrol_review` route. Only the fix stage uses `patrol.fix.agent` and the
`models.patrol_fix` route. For example, `patrol.fix.agent: opencode` with
`model: openrouter/stealth/ox-alpha` and `effort: high` selects OpenCode only
after a finding is admitted for repair. The controller supplies the bounded
OpenCode permission policy directly. Inbox/review may write only their exact
report and receive no shell permission when OpenCode is deliberately selected
as the Patrol review agent. Fix may edit the owned worktree and its exact report
and receives the explicit `Bash(*)` grant needed to reproduce, test, and commit
the repair. This full-shell grant has the authority of the Hive OS user;
artifact custody and Git validation remain the outcome boundary. The managed
Inbox, Fix, and Review custody manifest includes the complete shared
orchestrator-owned set, including `task.md`, the authoritative task journal,
and both derived projection files, plus the Patrol-specific manifests and
receipts. An agent cannot establish a trusted projection or journal state by
rewriting those task-folder files during its run.

Every managed Patrol Fix agent is also told to return its report as the exact
final JSON object. If the agent exits successfully without creating the report,
the controller may materialize only that exact, untruncated JSON object before
Artifact Firewall validation. Prose, arrays, truncated output, and any existing
path are not accepted; in particular, a dangling report symlink remains a
custody violation rather than being replaced by the fallback.

Managed Inbox, Fix, and Review failures normalize the existing agent process,
provider, parser, and Artifact Firewall facts into the versioned Patrol Fix
attempt-diagnostic schema before custody returns. The artifact records the
opaque attempt ownership generation (not the numeric task input epoch), a
snake-case failure code and owner, process termination state, provider class
and retry hint without provider response text, report/parser state, firewall
restoration, and bounded publication-policy-redacted detail. A clean report
after Pi's recovered internal provider retry remains successful and emits no
failure frame. Invalid Fix reports emit `fix_report_invalid`; invalid reports
from the other managed stages emit `agent_report_invalid`. Silent failures
receive a supervisor-authored terminal diagnostic. The first-party controller
also publishes semantic failure facts before reraising known worktree head
drift, dirty worktrees, validation mutation, and Hive-state Git index-lock
conflicts, so those failures retain their typed cohort codes even when no
managed agent seam ran. Publication secret blocks instead use the sanitized
terminal receipt below and do not fail the attempt.

Independent review hashes the bounded Git diff as raw bytes, then validates and
labels a copy as UTF-8 before placing it in the canonical prompt context. Valid
non-ASCII patch text therefore remains reviewable without changing its evidence
digest; malformed diff bytes fail closed before an agent launches.

`Hive::GithubPublication` is the single PR-publication mechanism used by
Patrol Fix and the normal coding open-PR path. It owns durable push/create
intent, remote reconciliation, expected-absence leases, and exact hosted
observation. Discovery code has no remote mutation authority. Escalation creates
one linked standard coding task through `TaskCapture`; it does not create a
GitHub issue.

A Patrol Fix `secret_detected` publication refusal parks that exact generation.
Publish appends one sanitized `publication_block` receipt containing safe field
names, evidence receipt IDs, HEAD/diff hashes, the policy version, and a fixed
summary. It never stores matched secrets or source snippets. No authentication,
push, or PR creation occurs before this block. The `diff` field covers the full
commit range, including secrets removed from the final diff. Repeated runs
return the existing park without remote calls or cleanup. Status names the
operator as owner; daemon dispatch and ordinary retry cannot release it.

There is no publication-specific reopen action or routing back to earlier
stages. The operator must correct the source problem before starting a new
task through the normal workflow. Historical secrets require cleaning history,
not merely editing the latest file. The old blocked generation stays parked.

## One-time historical import

`script/migrate_patrol_findings.rb [PROJECT_ROOT] [--dry-run]` reads active
ordinary findings from the local native StateStore and accepted historical
Architecture Patrol `fix` and `discuss` dispositions from JobStore. Both lanes
use their current source adapters and reserve immutable snapshots in the shared
`AdmissionStore`; the importer creates no workflow task folders. The ordinary
admission scheduler materializes a task only after semantic admission and
workflow-capacity checks. Dismissals and historical action records are ignored.
It is the only Patrol migration path. It has no daemon hook, timer, module
owner, cutover state, rollback, qualification report, or compatibility reader.

The importer is idempotent by each adapter's occurrence identity and source
digest. Duplicate ordinary finding IDs and conflicts across either lane are
rejected before mutation; existing matching admissions are reused. It never
scans existing workflow tasks.
Legacy ordinary findings without a target revision use the current
default-branch revision; secret-like source text is redacted before admission
bytes are written.

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
- Secret-policy publication blocks are append-only, operator-owned, and cannot be
  released by ordinary retry or automatic stage routing.
- Generic `hive run` auto-rebase never runs for a controller workflow; exact
  checkout movement belongs to the controller's receipts and transitions.
- Historical import is explicit, local, one-time, and never daemon-triggered.
- Existing admission index construction is explicit through `hive migrate`;
  runtime reads stay bounded and never scan-rebuild the projection.
- Ordinary Patrol retries idempotent admission publication for an already
  persisted active finding, so an interrupted handoff cannot strand evidence.

## Backlinks

- [[commands/patrol]]
- [[commands/refactor-patrol]]
- [[modules/daemon]]
- [[state-model]]
- [[testing]]

### Credential-bearing URLs in publication evidence

Patrol Fix PR bodies omit URL userinfo from copied review and finding evidence.
Original task receipts remain unchanged. Betterleaks still checks the generated
body and exact commit range before publication; other detected secrets block.

## Known gaps

### Unified Patrol Fix live execution

#### Source S16, lines 273–325: Unified Patrol Fix live execution

The current simplification keeps historical Architecture Patrol issue-action and
policy fields readable for replay compatibility. The retired issue effect is
still parked fail-closed; removing that persisted vocabulary is separate from
the completed Patrol Fix migration-subsystem deletion.

The Inbox/Fix/Validate/Review/Publish path has focused local proof for exact worktree and
receipt custody, failed-validation continuation, independent decision parsing,
generation-safe rework/reopen, parked outcomes, and exactly-once coding
successors. Local bare remotes and injected GitHub inventories also prove
expected-absence publication, lost-response reconciliation, exact hosted-PR
adoption, strict publication receipts, cleanup diagnostics, and the PR-gated
Done move. The workflow has not yet run a real configured provider or GitHub
publication against a disposable project. End-to-end dogfood belongs to the
plan's final lifecycle verification; no current evidence claims live PR
production.

The one-time importer has focused proof for active-finding selection,
deterministic idempotency, dry-run behavior, and normal `TaskCapture` output.
There is intentionally no migration preflight, cutover state, rollback, or
runtime reconciliation path.
U11 closes the four admission-runtime blockers without adding another
coordinator: the daemon inventories only exact Patrol Fix task manifests,
fails visibly on owned corruption while ignoring unrelated task bytes, binds
the complete owned inventory count/digest/head, and supplies one deterministic
top-64 context capped at 192 KiB. Exact source/alias/lineage overlap ranks
before path and lexical relevance; every selected row carries bounded evidence,
affected code, remediation, manifest digest, and a digest of those exact bytes.
Each reserved decision attempt receives exactly one provider launch through
the existing `ChildSupervisor`, with no candidate-page fan-out. An occurrence
may retry later under bounded provider backoff. A durable AdmissionStore
reservation fences late, expired, restarted, or never-launched children, and
the parent alone retains materialization and source-acknowledgement authority.

The remaining gap is live delivery evidence, not local runtime behavior. The
new fake-provider lifecycle proves both source engines, a cross-source duplicate,
rework, a separately parked escalation successor, one local publication, and
restart replay. The frozen historical corpus exercises the four production LLM
prompt/parser seams and the dogfood report schema can retain one exact source to
PR trace, but no configured real provider, enabled-project discovery round,
hosted GitHub PR, hosted CI, or natural finding was executed in this change.
Keep release/dogfood incomplete until the opt-in historical corpus has actual
provider/model receipts and one naturally discovered finding reaches `done`
with an exact PR and zero duplicate replay.

An August 26 dogfood run exercised the real Pi/Ox Alpha Fix launch and durable
markerless recovery, but exposed that pre-fix first-generation worktrees had
treated Inbox's local checkout `HEAD` as their creation base. On a divergent
operator checkout this carried unrelated local commits into the resulting PR.
New first generations now fail closed onto exact `origin/<default>` OIDs; the
remaining live-delivery proof must come from a task admitted after that cutover
and reach one focused hosted PR.

### Patrol dispatch incident demand baseline (2026-08-26)

#### Source S17, lines 328–347: Patrol dispatch incident demand baseline (2026-08-26)

The sanitized 600-charge incident replay pins the Patrol/coding, outcome,
generation-stage repeat, stage, and failure-class aggregates without retaining
task identities, provider output, secret material, credentials, or host paths.
It also characterizes the former undifferentiated daily pool: once Patrol had
used all 600 charges, later-stage Patrol progress, first-attempt Patrol work,
and non-Patrol work were all starved even though later-stage ordering remained
stable. Source and focused tests now pace three matching receipt-bound typed
Patrol failures with one durable probe across restart while leaving task
capacity as the shared safety boundary. The remaining gap is installed-daemon load
and UTC-rollover proof over a live representative backlog; the sanitized replay
is deterministic local evidence, not that operational soak.

The preceding seven complete UTC days cannot be reconstructed into a
defensible non-Patrol demand series from the retained Attempts v4 records.
Historical `1-inbox` attempts do not all carry an unambiguous durable workflow
identity, so classifying them as Patrol or coding would invent evidence. No
task-capacity partition is inferred from that missing history: Patrol discovery
already has separate scan concurrency and per-engine daily allowances, while
Attempts capacity remains a shared safety boundary.

### Separate Patrol launch lanes need installed rollover proof (2026-08-21)

#### Source S33, lines 955–963: Separate Patrol launch lanes need installed rollover proof (2026-08-21)

Focused tests prove separate ordinary and Architecture per-project daily launch
allowances, durable pre-spawn reservations, lane-local provider holds, and UTC
rollover. The current source has not yet been installed and observed across a
UTC rollover with both lanes active. Capture one live medium project that
exhausts each four-launch lane independently, emits no fifth process in either
lane, avoids hot retry, and resumes both lanes after rollover. Token totals are
telemetry-only and do not authorize launches.

### Patrol quota-progress fixes need post-release dogfood (2026-07-19)

#### Source S45, lines 1115–1160: Patrol quota-progress fixes need post-release dogfood (2026-07-19)

Historical note: the split ordinary/architecture launch accounting described
below was superseded on 2026-08-20 by the shared mode-derived daily ceiling.
The remaining current live-proof requirement is recorded in “Shared Patrol
launch ceiling needs installed mixed-lane proof” above.

A live medium ordinary-patrol run exposed that the configured 12-feature batch
could consume its three-launch cycle envelope, report the remaining features as
errors, and leave the cursor at zero. Live architecture jobs then exposed the
same exhausted shared 8-launch UTC-day ceiling as one synthetic failure for
every remaining feature and retried it every minute without starting another
provider process. Post-release v0.6.2 ordinary patrol mapped 209 features,
reviewed exactly the launch-aware three-feature batch without errors, advanced
its clean prefix, and ranked one source-anchored systemd startup defect at alpha
80. Architecture Patrol reached the isolated exact checkout and retained its
raw response, proving the dirty-checkout and ephemeral-evidence fixes, but
exposed a valid leading JSON fence followed by plain-text rationale that v0.6.2
rejected. The v0.6.3 parser accepts that canonical document shape; exact-main
dogfood then completed clean PR-scoped reviews and a full scan produced the
meaningful `invert-usage-error-contract-ownership` thesis above the configured
0.25 discovery floor. Automation correctly rejected it for unverified evidence
and missing behavior validation. Cross-feature scope is no longer independently
disqualifying: exact replays of the two bounded PR 785 documentation findings
under the revised policy are admissible and auto-fix eligible, with built-in
docs diff validation before normal PR review. Durable architecture review run
directories still have no automatic retention policy, so long-running
installations should monitor `.hive-state/refactor_patrol/runs/` growth.

Exact-source dogfood on 2026-07-20 replayed merged PR 785 through 13
architecture reviews while ordinary launch accounting remained at zero,
crossing the ordinary eight-launch ceiling without consuming it. The accepted
theses became review issues 811 and 812. A separate non-dry ordinary patrol run
found a reachable bot logger crash, independently proved fail-before and
pass-after, opened pull request 814, and entered 6-review. This closes the local
delivery-path uncertainty, but the installed package is still v0.6.4 and has
not exercised the proposed split accounting or default issue-filing behavior;
v0.6.5 packages those changes. Installed v0.6.4 dogfood also exposed a
separate ordinary-patrol wire-contract gap: reviewers returned meaningful
source evidence as multiline excerpts or annotated paraphrases, while the
validator requires every snippet to be an exact substring of one claimed
source line and therefore rejected the complete finding. v0.6.5 aligns the
reviewer prompt with that existing fail-closed validator. Retain this gap until
the installed v0.6.5 package opens meaningful ordinary and Architecture Patrol
work without dirty-checkout, quota-churn, response-envelope, or evidence-
contract errors.

### Patrol Fix has no interrupted-attempt recovery (2026-08-21)

#### Source S64, lines 1508–1525: Patrol Fix has no interrupted-attempt recovery (2026-08-21)

Ordinary patrol used to settle a process-interrupted local fix attempt in
`Patrol::Fixer#recover_interrupted_attempt`: adopt the exact patch receipt, or
prove the deterministic checkout disposable before recording
`interrupted_fix_attempt`. Consolidating discovery and fixing removed both
`Patrol::Fixer` and `RefactorPatrol::Fixer`, and the unified
[[modules/patrol]] Fix workflow has no equivalent — a killed Patrol Fix child
can leave a worktree and branch behind with no receipt, for either source.
`Commands::Patrol` no longer calls `recover_pending_fix_attempts!` at all.

This is a known regression against `main`, not a resolved gap. The replacement
belongs in the Patrol Fix stage machinery (worktree generations plus the
admission store already hold the durable identity the old proof reconstructed
from Git), so port it there rather than reviving the deleted engines. Keep this
gap open until Patrol Fix proves an interrupted local generation either
adoptable or disposable before reuse, and preserves dirty, broken-registration,
or uniquely committed residue as operator-owned.

### Patrol background discovery cadence (2026-08-28)

#### Source S69, lines 1595–1612: Active-only status projections and Patrol cadence still need installed dogfood (2026-08-28)

Patrol candidate enumeration is now decoupled from scheduler cadence through a
one-slot background worker. The dispatcher can publish another authoritative
task snapshot while a prior discovery pass is still running; it harvests the
completed hints later and keeps reservation, capacity gates, and spawn on the
main thread. Architecture discovery's durable maintenance stays under its
existing store locks, with stale diagnostic writes rejected by an observation
fence. Focused source tests prove non-overlap, repeated publication carrying a
fresh task source, once-only stall telemetry, truthful non-drained shutdown,
retry-deadline enforcement, and rejection of candidates made stale by newer
failure backoff or registration/config changes. This has not yet been installed
and observed through a discovery pass longer than the snapshot-validity window,
so the live cadence claim remains a dogfood gap, not a source-code gap. The
harvest-time reservation/ownership checks still run on the dispatcher thread;
live timing should determine whether they need a separate bounded optimization.
The PR sweep also identified competing process waits between discovery and the
ancillary supervisor. Its focused regression uses real subprocesses and the
Gh capture path; it does not replace the installed slow-discovery cadence proof.
