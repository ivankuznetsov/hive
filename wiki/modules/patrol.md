---
title: Hive::Patrol
type: module
source: lib/hive/patrol/
created: 2026-05-28
updated: 2026-07-31
tags: [module, patrol, review, worktree, pr, codex]
---

**TLDR**: `Hive::Patrol::*` is the ordinary repository-patrol engine behind [[commands/patrol]]. It keeps clawpatch-style work units and audit state as plain JSON under `.hive-state/patrol/`, delegates review/fix reasoning to configured Hive agent profiles, records patrol review/fix token usage in `Hive::UsageDb`, validates fixes in isolated worktrees, opens PRs, and by default hands opened PRs into the normal `6-review` flow through `Hive::Patrol::ReviewHandoff`. The separately configured, post-merge architecture patrol lives under `Hive::RefactorPatrol::*`; the two schedulers share the project/day input-plus-output token pool while architecture gets a larger cycle allowance and its own daily review cap instead of consuming the ordinary daily launch count, and they do not share state, mapping, policy, or action ledgers.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Patrol::Mapper` | `lib/hive/patrol/mapper.rb` | Ordinary patrol enables the shared architecture capability: non-overlapping language-neutral source/manifest components with dependency-ranked context and subsystem tests, plus one primary review per command or grouped manifest-script contract. Command paths remain component context, not duplicate evidence anchors. Legacy route/package/monolithic-test slices remain available only to callers that omit that capability. |
| `Hive::Patrol::SourceReader` | `lib/hive/patrol/source_reader.rb` | Shared root-confined, regular-file-only, 256 KiB bounded reader used by architecture mapping and leverage measurement. It resolves tracked symlinks beneath the canonical project root and skips external/device targets before reading. |
| `Hive::Patrol::Feature` | `lib/hive/patrol/feature.rb` | Durable feature record: `id`, `kind`, `entrypoints`, `owned_files`, `context_files`, and `tests`. |
| `Hive::Patrol::FeatureBatch` | `lib/hive/patrol/feature_batch.rb` | Selects the deterministic SHA-bound rotating component batch and returns the next persistent cursor. `Commands::Patrol` strictly fetches the explicit remote head for each new sweep, fails closed rather than scanning stale local main when that fetch fails, and records an explicit active snapshot so an in-progress sweep can finish its pinned SHA even when default advances or the first batch errors at cursor zero. If that commit becomes unmaterializable, the command starts from the current default and `FeatureBatch` resets the cursor. |
| `Hive::Patrol::Reviewer` | `lib/hive/patrol/reviewer.rb` | Requests zero-to-three evidence-backed production defects per feature from an initial view capped at four owned files and 32 KiB; bounded output must match the exact JSON envelope and is accepted atomically only when every admitted item has complete contract/impact/root-cause/scope/reproduction/validation fields, selects an operator-configured validation key, and its confined evidence line contains the supplied snippet. Finding ids include the unique review-run id so audit records are immutable. |
| `Hive::Patrol::Finding` | `lib/hive/patrol/finding.rb` | Durable finding record with delivery metadata (`scope`, contract, impact, root cause, reproduction, validation, computed alpha score), exact target SHA, selected validation key, and explicit active/resolved/rejected/superseded lifecycle. The published v3 schema carries those fields while the original v1 and pre-lifecycle v2 contracts remain pinned. |
| `Hive::Patrol::FindingRegistry` | `lib/hive/patrol/finding_registry.rb` | Reconciles existing finding records with target-scoped merged/open fingerprint state and dismissals. Same-target terminal duplicates stay suppressed; shipping runs reuse a same-target active canonical record without persisting the reviewer's duplicate. Newer-target recurrences form a new active lineage, superseding older active matches while preserving resolved/rejected history. Exact-fingerprint and category/token indexes keep admission linear in the relevant semantic bucket, while lifecycle transitions persist the already-loaded record with one timestamp. |
| `Hive::Patrol::Fingerprint` | `lib/hive/patrol/fingerprint.rb` | Structured findings use a feature-independent semantic SHA over category, primary evidence path, contract, and root cause. Historical v1 findings retain the legacy identity fallback. Stored title/root-cause tokens provide cross-wording similarity across every durable finding, while feature metadata supports outcome calibration. |
| `Hive::Patrol::CandidateSelector` | `lib/hive/patrol/candidate_selector.rb` | Applies production/history/active-feature hard gates, computes deterministic 0–100 alpha from validated proof fields, clusters semantic duplicates even within one feature, maps legacy slice IDs narrowly to current components, enforces per-feature diversity, and returns a globally ranked portfolio. Successful merged history is not treated as negative alpha. |
| `Hive::Patrol::Fixer` | `lib/hive/patrol/fixer.rb` | Strictly fetches an exact base and directs the agent through four bounded inspect/reproduce/edit/proof responses without post-edit self-validation. A completed `fix.json` ends the agent phase, but only asks Hive to continue: the proof reader rejects unsafe files and caps bytes before parsing, then Hive applies the changed-path guardrail, overlays declared regressions onto an isolated base, requires a normal regression-identified failure and patched pass, and runs broader validation under `timeout_sec.patrol`. An errored or timed-out run without a completed proof fails closed as `fix_agent_failed`; half-finished changes are never shipped. Agent rejection is an attempt outcome, not durable resolution; reconciliation and failed handoff states reuse the exact validated patch. |
| `Hive::Patrol::Validator` | `lib/hive/patrol/validator.rb` | Owns configured validation-name/command selection and runs those operator-configured commands in the fix worktree. Reviewer, selector, command stamping, and fixer all consume the same key discovery. A normal patrol command rejects an empty command set before state mutation or agent work; direct fixer callers still fail closed. |
| `Hive::Patrol::PrOpener` | `lib/hive/patrol/pr_opener.rb` | Fail-closed secret-scans the title, body, and exact validated diff; verifies a clean exact local head, remote base, leased push, remote head, and created/existing PR identity; and invokes `ReviewHandoff`. The hosted PR result and a typed publication outbox entry are committed atomically with the terminal effect receipt. `StateStore` alone projects that immutable binding into `reconciliation_pending` before acknowledging the exact outbox tuple. Retries therefore reconcile only the receipted repository/URL/base/head/patch/worktree, retain the worktree until projection and handoff settle, and cannot redispatch the PR effect after a crash. New and retried handoffs require the hosted base OID and perform a final live remote base/head check immediately before task publication. Dynamic publication diagnostics are separate from closed reason codes. |
| `Hive::Patrol::ReviewHandoff` | `lib/hive/patrol/review_handoff.rb` | Creates a synthetic `6-review/patrol-.../` task for an opened patrol PR when `patrol.review_prs` is not false, preserving the patrol worktree and observed proof so the standard review daemon can run reviewers/triage/fix/browser flow. Mandatory and optional calls use the same fingerprint-locked exact reconciliation, so a retry after rename/fsync ambiguity reuses the matching task and rejects PR/head identity conflicts. Staging/quarantine renames use the shared best-effort directory-fsync policy. |
| `Hive::Patrol::AgentLaunch` | `lib/hive/patrol/agent_launch.rb` | Builds the provider-specific patrol launch envelope. Claude reserves 20,000 tokens for provider-owned initial context plus one conservative token per prompt byte, uses a verified minimal review/fix tool set, and caps reviews at four completed turns; the fourth is emergency JSON finalization only. |
| `Hive::Patrol::ReviewErrorDetails` | `lib/hive/patrol/review_error_details.rb` | Converts an agent resource-exhaustion result into the shared durable review-error detail envelope used by ordinary and architecture patrol. |
| `Hive::Patrol::TokenBudget` | `lib/hive/patrol/token_budget.rb` | Shares input-plus-output safety ceilings across ordinary review/fix and architecture discovery/action phases and supplies an actual per-launch streamed-token cap to `Hive::Agent`; cached usage remains telemetry only. A launch is refused before spawn when the remaining per-agent/cycle/day token allowance cannot cover `AgentLaunch`'s initial reserve. A project-keyed advisory lock serializes full agent lifetimes so daily headroom cannot be double-spent by concurrent workers. Ordinary fixes default to 2x per-agent headroom for edit/test/proof turns; architecture defaults to a 2x cycle/per-agent envelope and is accounted separately from the ordinary daily launch-count ceiling. Architecture reviews have an independent daily cap of 8 while fixes retain capacity. Both retain the shared native budget guard and durable current-day token ceiling. Missing architecture usage is recorded separately and bounded by `max_architecture_unmetered_spawns_per_day` (default `96`) across fresh budget instances. |
| `Hive::Patrol::Dismissals` | `lib/hive/patrol/dismissals.rb` | Reconciles closed-unmerged patrol PRs into `dismissed.json` so the same finding is not immediately re-filed. Retryable publication entries match only their exact receipted PR URL and remain retryable while that PR is open. |
| `Hive::Patrol::BaseStateStore` | `lib/hive/patrol/base_state_store.rb` | Shared JSON lifecycle for ordinary patrol and architecture patrol's legacy reporting state: directory creation, state/fingerprint/dismissal files, run artifacts, and tolerant reads. It delegates atomic replacement to `Hive::AtomicFile` while preserving the stores' prior no-fsync behavior. |
| `Hive::Patrol::StateStore` | `lib/hive/patrol/state_store.rb` | Defines the ordinary-patrol collections, is the sole ordinary `EffectGateway` composition root, and exposes the ordinary product recovery API over the shared occurrence journal. Fingerprint writes require the configured gateway and persist the exact canonical set/delete operation in the occurrence intent. Before any fingerprint read or suppression decision, recovery walks every recovery-active predecessor capture, reconciles or retry-safely redispatches that exact operation, and rejects multiple nonterminal predecessors for one fingerprint. It also projects typed publication outbox entries into one immutable fingerprint binding, writing the binding before tuple acknowledgement so crash-before-ack replay is an exact no-op. Fingerprints retain PR mapping only; the removed effect-intent maps are not a parallel retry authority. |
| `Hive::Modules::Migration::PatrolDecisionProjection` | `lib/hive/modules/migration/patrol_decision_projection.rb` | Strict shared value for the immutable selection result. Separate ordinary and architecture projectors validate their own input vocabularies before constructing it; terminal outcome and effect evidence are not selection fields. |
| `Hive::Modules::Migration::OccurrenceJournal` | `lib/hive/modules/migration/occurrence_journal.rb` | Public durable-occurrence facade. It composes a pure `OccurrenceRecordValidator`, one `OccurrenceRecordStore` lock/read/write owner, bounded `OccurrenceJournalState`, typed `OccurrenceOutbox`, `OccurrenceEffects`, stable sender locks, and durable attempt allocation; the final capture must retain the exact selection, reject nonterminal effects, and bind exactly the terminal receipt ids. Receipt and publication entries may share an id, so acknowledgement is bound to the exact `(kind, id, digest)` tuple. `StateStore` and `JobStore` remain the separate product-facing recovery authorities. |
| `Hive::Modules::Migration::OccurrenceJournalState` | `lib/hive/modules/migration/occurrence_journal_state.rb` | One bounded 64 KiB coordination cell per product journal. It persists compacted schedule high-water/floor fences, a bounded exact fence for non-sequenced terminal captures, and normalized restart-safe recovery backoff; it contains no effect, outbox, or product work state. |
| `Hive::Modules::Migration::OccurrenceRecoveryIndex` | `lib/hive/modules/migration/occurrence_recovery_index.rb` | Descriptor-confined, bounded locator for exact reserved or projection-pending occurrence ids. Its generation is fenced by `OccurrenceJournalState`; missing, malformed, stale, or dirty state receives one bounded authoritative-record repair. It never authorizes work or stores effect bytes. |
| `Hive::Modules::Migration::EffectDelivery` | `lib/hive/modules/migration/effect_delivery.rb` | Product-neutral composition facade shared by the two direct-`Object` gateways. `EffectAdmission` owns live owner/config/module-generation/grant/claim policy, `EffectSender` owns stable-lock/fence/reconciliation transitions, and `EffectReceiptLedger` owns terminal replay and observational receipt projection. The occurrence store, not the sender or ledger, mints authoritative receipt bytes. Dependencies point toward the injected product store; none of these collaborators owns persistence. |
| `Hive::Patrol::EffectGateway` | `lib/hive/patrol/effect_gateway.rb` | Thin ordinary-patrol product port over `EffectDelivery`. It preserves the ordinary `perform!` and reconcile-only adoption API while authorizing ordinary state, finding, attempt, branch, PR, and review-handoff sinks. |
| `Hive::RefactorPatrol::EffectGateway` | `lib/hive/refactor_patrol/effect_gateway.rb` | Thin Architecture Patrol product port over `EffectDelivery`. It retains architecture claim and `NotDelivered` policy while action claim generation fences authorization but remains outside semantic remote-effect identity. |
| `Hive::RefactorPatrol::ArchitectureProjectBinding` | `lib/hive/refactor_patrol/architecture_project_binding.rb` | Leaf boundary that builds the exact registered `{project_id, name, repository}` descriptor, validates it against immutable PR source provenance, and rejects exact descriptor drift. It depends only on URI parsing and typed errors, so occurrence persistence does not load transition, ownership, or JobStore layers. |
| `Hive::RefactorPatrol::TransitionGateway` | `lib/hive/refactor_patrol/transition_gateway.rb` | Non-persistent product port that routes architecture `job`, `discovery`, and `action` transitions through the architecture gateway. It writes only by invoking a JobStore transition and replays JobStore after duplicate delivery. |
| `Hive::RefactorPatrol::ArchitectureOccurrenceStore` | `lib/hive/refactor_patrol/architecture_occurrence_store.rb` | JobStore's product adapter over `OccurrenceJournal`. It resolves the exact immutable `occurrence_id` held by the v3 job aggregate and delegates all occurrence/effect state; there is no sidecar binding or fallback index. |
| `Hive::RefactorPatrol::JobStore` | `lib/hive/refactor_patrol/job_store.rb` | Architecture Patrol's v3 aggregate and product recovery authority. Each job owns immutable occurrence/intake transition ids; claim, action, job-level, and durable diagnostic-episode records append exact transition ids and semantic digests. Construction and semantic mutation call sites are statically confined to the declared composition and transition ports. |
| `Hive::RefactorPatrol::ArchitectureIntakeTransitions` | `lib/hive/refactor_patrol/architecture_intake_transitions.rb` | Shared command/daemon coordinator for manifest occurrence reservation, exact enqueue reconciliation, and transition identity. Callers retain policy and cadence; this collaborator adds no persistence of its own. |
| `Hive::RefactorPatrol::ActionTransitions` | `lib/hive/refactor_patrol/action_transitions.rb` | Facade used by `ActionRunner`: claim-scoped CAS/reconcile/receipt operations and job-level plan/link/block transitions live in separate coordinators over one immutable transition context. `ActionRunner` retains thesis, policy, fixer, publication, and issue decisions. |
| `Hive::RefactorPatrol::DiscoveryTransitions` | `lib/hive/refactor_patrol/discovery_transitions.rb` | Facade used by `RefactorPatrolScheduler` and its command child: discovery claim/checkpoint/release and diagnostic block transitions live in separate coordinators. The scheduler claims and attaches the exact child process; `--job-manifest` reconstructs the non-claiming command-side coordinator before incrementally checkpointing through that attached token. `ArchitectureOccurrenceLifecycle` alone reserves/finalizes occurrences and recovers capture/event/receipt projections; the scheduler retains cadence, candidate selection, spawn, and envelope handling. |
| `Hive::RefactorPatrol::ClaimMaintenanceTransitions` | `lib/hive/refactor_patrol/claim_maintenance_transitions.rb` | Narrow non-outcome port for generation-fenced child-process attachment and discovery/action heartbeat renewal. Command and scheduler roots cannot call those JobStore mutators directly. |
| `Hive::Modules::Migration::PatrolEvidence` | `lib/hive/modules/migration/patrol_evidence.rb` | Strict immutable ordinary/architecture capture, intent, and receipt values shared only as an observation protocol. `EvidenceStore` appends canonical records, maintains bounded occurrence/intent indices, and repairs them through portable lexicographic pages whose cursors freeze one high-water inventory plus an order-independent filename fingerprint. `ManagedDirectory` rejects linked managed components and descriptor-binds its bounded reads, locks, and atomic writes; evidence remains observation-only and has no mutation or recovery authority. |

## State

Patrol state is deliberately inspectable and removable:

```text
.hive-state/patrol/
  features/*.json
  findings/*.json                 # lifecycle + target/validation identity
  patches/*.json
  runs/*/                         # agent transcripts/output
  runs/selection-*.json           # immutable score/decision audit
  state.json                      # cycle state only
  fingerprints.json               # publication mappings only
  occurrences/occ-*.json          # authoritative occurrence/effect/outbox cells
  occurrences/journal-state.json  # bounded fences + dirty generation + recovery backoff
  occurrences/.sender-locks/*.lock # stable live-sender flock authorities
  occurrences/.attempt-locks/*.lock # schedule-attempt allocation locks
  occurrences/.journal-state-locks/*.lock
  occurrences/.inventory-locks/*.lock
  dismissed.json
.hive-state/module-runtime/migration/patrol-evidence/
  captures/*.json
  receipts/*.json
  indexes/occurrences/*.json
  indexes/intents/*.json
```

The managed repository worktree is not edited by fixes. `Fixer` uses [[modules/worktree]] to create a branch named `hive-patrol/<feature-id>-<fingerprint8>` under the project's worktree root. When `patrol.review_prs` is enabled (default), that worktree is kept after PR creation and referenced by a synthetic `6-review` task with display name `Patrol: <finding title>`. When disabled, the successful local worktree is removed after the branch is pushed and the PR opens.

## Patrol PR reviewer (cheap by default)

Patrol PRs flow into `6-review` and are reviewed by `patrol.review.reviewers` (a separate set from human PRs' `review.reviewers`) — see [[stages/review]] `run_reviewers` → `patrol_task?` routing. Because patrol opens many PRs per cycle, the **DEFAULT patrol reviewer is the native single-pass `codex review`** adapter (`kind: codex_review`, `name: codex-native-review`), not the multi-persona `ce-code-review` fan-out (6–18 subagents). It runs one tuned, read-only `codex review` and captures stdout into the GFM-checkbox findings file the triage/fix loop already consumes, so the loop is unchanged. See [[modules/reviewers]] `Reviewers::CodexReview` for argv/format details. Operators can override `patrol.review.reviewers` per project to add the ce-code-review fan-out or Claude.

## Ordinary patrol versus architecture patrol

Ordinary patrol scans the current repository into language-neutral components
and command-contract features, then attempts globally ranked production-defect
fixes above the alpha gate. Documentation, test-gap, and maintainability
observations are excluded from its automatic lane. Architecture patrol
([[commands/refactor-patrol]]) is triggered by an immutable merged-PR
occurrence, maps language-neutral feature and documentation slices from that
merge, and requires every architectural thesis to receive a durable accepted,
flagged, or suppressed disposition before any separately authorized action.
Architecture v2 fetches and pins an exact committed default-branch SHA, then
runs mapper, leverage, and reviewer source reads from an ephemeral detached,
clean worktree. Persistent state and collision ledgers remain rooted in the
registered project, so a developer's active branch or uncommitted files neither
alter nor block the analysis. A partial retry rematerializes its original
pinned SHA even after the default branch advances; an explicit replay of a
terminal occurrence instead pins the new current-default head. Unclaimed dry
runs use unique analysis-tree keys, and deterministic claimed retries prune an
orphaned Git worktree registration when its directory has disappeared.

The two mappers retain deliberately different breadth, but both reviewers now
start from at most four owned files selected with a 32 KiB source budget.
Ordinary mapping still records four owned plus four context files, while
architecture keeps six plus six for deterministic hotspot/leverage
measurement. Context and test paths are not preloaded into the ordinary review
prompt, and an oversized first entrypoint is retained. Both prompts permit
only one evidence-driven follow-up round and explicitly prefer an empty result
to speculation. A Claude review receives only `Read`, `Grep`, `Glob`, and
`Write`, with slash commands disabled; a fix additionally receives `Bash` and
`Edit`. The third response must finalize; a fourth is allowed only as emergency
finalization when the provider misses that contract. After a non-empty output
artifact and its final usage delta settle in either provider event order, Hive
terminates the child and lets the existing schema/evidence parser decide
whether the result is admissible.

The two systems share only the legacy JSON persistence mechanics in
`Hive::Patrol::BaseStateStore`; their domain records and proof remain separate.
They deliberately retain separate namespaces:
`.hive-state/patrol/` for ordinary patrol and
`.hive-state/refactor_patrol/v2/` for retained architecture manifests,
semantic families, runs, logs, and result receipts. Architecture jobs,
occurrences, and the job-query index live only under
`.hive-state/refactor_patrol/v3/`; a released-v2 jobs directory blocks runtime
until an operator explicitly archives it and accepts an empty v3 start.
`Hive::Daemon::PatrolArbiter` is the only shared
orchestration seam: it alternates ready work under the project's
`daemon.max_concurrent_patrol_scans` capacity. Enabling architecture discovery
does not enable ordinary patrol or auto-fixing. Deduplicated GitHub issues are
its default human review surface, with an explicit
`issue_filing.enabled: false` opt-out; neither system can consume the other's
state as proof of completion.

## Daemon triggers

Patrol is **opt-in**. A project with **no patrol section at all** (or a patrol section that omits `mode:`) resolves to `enabled: false` — [[modules/config]] only derives mode knobs when `mode:` is **explicitly present** in the raw config. `medium` is the default offered by the `hive init` *prompt* (which writes an explicit `mode: "medium"` into the rendered template), never a config-resolution default, so legacy projects without a patrol block are never silently enabled.

Operators normally configure scheduling through `patrol.mode`, which [[modules/config]] resolves into cadence plus token, launch, native budget-equivalent, and per-launch token ceilings before the daemon sees the project config. `ultrapatrol`, `high`, `medium`, and `low` deliberately receive progressively smaller envelopes as cadence falls; `off` resolves to `enabled: false`. Measured input and output from both ordinary and architecture stages share the same project/day total; cached counts remain visible but uncharged. Ordinary fix stages apply `fix_budget_multiplier` (default `2`) only to their streamed per-agent cap so editing and proof do not consume review capacity; ordinary cycle/day token and launch limits remain unchanged. Architecture stages apply `architecture_budget_multiplier` (default `2`) to cycle token/launch limits and the streamed per-agent token cap, not the native budget-equivalent guard. Architecture stages ignore `max_agent_spawns_per_day`; reviews instead stop at `max_architecture_review_spawns_per_day` (default `8`) while architecture fixes remain eligible. Their multiplied per-cycle launch bound, shared daily token pool, per-agent cap, advisory lock, and native guard remain active. The two multipliers do not compound for architecture fixes. Unmetered architecture children also consume the separate `max_architecture_unmetered_spawns_per_day` safety ceiling (default `96`), preventing an accounting failure from bypassing durable limits across scheduler cycles. Explicit granular knobs always win over a set mode and survive the deep-merge even when no `mode:` is set.

Each patrol launch also needs enough remaining allowance for its profile's
provider-owned initial context reserve plus the rendered prompt bytes. If not,
`TokenBudget#acquire` returns `insufficient_launch_headroom` without spawning
or consuming another subscription-backed request. It returns the more specific
`daily_token_headroom` when the shared UTC-day remainder is the binding limit,
allowing architecture patrol scheduling to sleep until the next UTC window.
The same next-day pacing applies when the architecture-specific daily review
launch or unmetered-launch ceiling is exhausted.
This admission check covers
ordinary and architecture review/fix launches; neither multiplier can bypass
the shared daily project cap.

Ordinary review batching also accounts for that shared launch envelope before
agents start. It selects no more features than the tighter remaining cycle or
UTC-day quota can launch and, during a shipping run, reserves as many remaining
launches as possible up to `max_fix_attempts_per_cycle` while still reviewing
at least one feature. Dry runs may spend the whole envelope on review. A
structured terminal quota failure stops later fix attempts instead of creating
several doomed artifacts. When a later review fails, the SHA-bound cursor
advances past only the proven-clean prefix; the failed feature and remaining
suffix stay pinned for retry.

`Hive::Daemon::PatrolScheduler` still consumes the lower-level `patrol.trigger` modes. `continuous` dispatches when either the default branch SHA changed or `poll_interval_sec` has elapsed, allowing patrol to keep reviewing existing feature slices between infrequent merges. Each cycle persists a SHA-bound feature cursor; `last_scanned_sha` advances only after the full mapped sweep succeeds. `new_commits` therefore keeps dispatching successive batches until that sweep completes. `timer` dispatches solely from `last_run_at` age.

## First-party module adapters and ownership

`modules/patrol` and `modules/architecture-patrol` package the existing engines
as reviewed first-party modules. Their registered adapters translate immutable
module trigger snapshots into the existing command/engine seams; package code
is never loaded. Ordinary Patrol accepts schedule and `task.completed`, while
Architecture Patrol accepts schedule and `pull_request.merged`. The existing
merge reconciler remains the only GitHub intake producer.

The adapters deliberately do not relocate durable product state.
`.hive-state/patrol/`, `.hive-state/refactor_patrol/`, global architecture
action proofs, budgets, fingerprints, dismissals, claims, artifacts, and
recovery receipts remain authoritative. A durable migration ownership epoch
keeps legacy scheduling as the sole mutator during shadow comparison. Cutover
remains fail-closed until the migration report's current qualification
requirements, reviewer sign-off, and no unexplained or duplicate effects are
satisfied; rollback
restores legacy ownership without moving checkpoints or replaying events.
Missing or corrupt migration state cannot authorize a module mutator. The
reviewed legacy configuration is copied into the migration binding with its
digest and is the only configuration the adapters execute. A shared migration
lock spans the final legacy ownership check, scheduler reservation, process
spawn, and Architecture Patrol claim attachment; cutover and rollback take the
same lock exclusively. Status and doctor surface unadopted, fenced, and corrupt
migration state rather than reporting an apparently healthy active module.

Shadow comparison consumes exact independently persisted finalized
`PatrolCapture` records. Selection is immutable occurrence identity, not a
terminal-status shortcut: `selection_input` is validated by the separate
ordinary or architecture projector, and both produce the strict shared
`PatrolDecisionProjection`. Legacy producers persist the decision reached by
their actual branch/candidate path; only the module side projects the immutable
primitive input. A deliberately divergent pair therefore produces unexplained
comparison differences instead of agreeing by construction. The provisional
capture must have no outcome or effects. Finalization retains the exact
project, trigger, reservation, owner, selection input, and selection, then adds
a non-null `outcome_class`, structured outcome, and the exact terminal receipt
ids. Ordinary scheduling first reserves one authoritative occurrence and
records disabled, not-due, or due before the child runs. Architecture Patrol
reserves one occurrence from the strict merge manifest and threads its
job/phase selection through enqueue, discovery claims and checkpoints, action
claims and effects, and finalization; it does not mint a second scheduler
occurrence. Its capture project binding is the registered project's exact
`{project_id, name, repository}` descriptor, with `repository` copied from the
registration's `repository_identity`; the manifest registration and PR URL
remain the immutable source and trigger provenance.
The source-to-registry repository comparison is semantic and case-insensitive;
capture reuse compares all three stored descriptor fields exactly. Reservation,
replay, and finalization fail closed when those identities disagree. Missing,
malformed, foreign,
provisional, provenance-only, or schema-import captures remain non-comparable.
Module-native cron targets are suppressed while legacy or shadow owns either
product, preventing a second schedule producer.

Shadow-history qualification no longer materializes the full directory or
record set. `BoundedFileInventory` rejects excess and unexpected children
before record bodies are read, emits restart-portable lexicographic pages, and
freezes each scan at a cursor-bound high-water mark. `Report` consumes that
source incrementally into constant-sized per-module aggregates. The one-off v1
migration uses the same no-follow bounded reader for live evidence, checkpoints,
and archive collision checks; linked, special, or oversized archives fail
closed. Its v2 checkpoint binds the SHA-256 of the source, immutable archive,
and live replacement before a file can advance from pending to migrated.
Restart can adopt an already-written replacement only when all three bindings
still match. The completion stamp is written only after a fresh inventory proves
that no v1 live evidence remains. Migrated v1 records are archived,
non-comparable diagnostics; new native v2 records are accepted only through the
strict selection/outcome schema.

`Hive::Modules::CapabilityContext` still preflights installed grants, and each
mutation reloads the live owner epoch, enabled configuration, installed module
generation, and effective grants at its separate ordinary/architecture
gateway while migration admission remains held across the sink. Sender
liveness is not persisted: a process-local keyed mutex plus a stable, never-unlinked
`0600` flock file is the sole live-sender authority. The occurrence records
only `prepared`, `dispatch_uncertain`, or a terminal
`committed`/`reconciled`/`denied`/`failed` fact. A crash releases the kernel
lock and leaves `dispatch_uncertain`; exact absence remains unresolved unless
the product gateway's closed sink contract marks that sink retry-safe
(`state`/`finding`/`review_handoff` for ordinary Patrol and
`job`/`discovery`/`action` for Architecture Patrol). Remote branch, PR, and
issue absence never authorizes redispatch. The occurrence store mints a
terminal receipt once, persists its canonical bytes plus any typed publication
handoff in the same update, and returns those exact bytes on every replay. An
ordered outbox keeps failed evidence/event/publication projection retryable and
acknowledges exact typed tuples rather than bare ids. Shadow authority can emit an
`attempted` evidence receipt but cannot alter StateStore, JobStore, GitHub, or
ReviewHandoff. StateStore and JobStore are the only product recovery
authorities; the append-only evidence tree is never a retry input. First-party
modules receive no consent bypass.

The journal streams its initial bounded filename snapshot and never constructs a
second recovery inventory. Lock acquisition is ordered
identity → journal state → inventory → occurrence record. Scheduled ordinary
attempts, module-hook occurrences, and Architecture Patrol merge/job occurrences
carry a canonical window plus generation, so completed identities compact into a
monotonic high-water/floor instead of an ever-growing exact set. Low-volume
manual/direct captures use a bounded exact-digest fence. When that fence is full,
the journal retains terminal records and fails closed rather than permitting a
replay. Recovery failures persist one bounded UTF-8 diagnostic cell with
60/300/900-second retry backoff; successful generation-matched recovery clears
it after restart.

The candidate-side ordinary qualification driver now has a private
`after_module_decision` interruption boundary. It injects a one-shot Attempts
worker-release reader before module-hook admission and retains the only writer.
The module dispatcher invokes the driver only after the admitted decision is
durably appended; by then the detached supervisor has also persisted the
blocked worker identity and returned its claimed handoff. The driver then calls
`Process.exit!(76)`, so process exit closes the sole writer without releasing
the worker. The supervisor treats that EOF as a temporary store failure,
terminates the worker, and leaves a nonterminal running attempt for the next
process to reconcile. Status 76 is qualification-private and is not part of
Hive's public exit-code contract. This slice establishes the real interruption
point only; restarted reconciliation, recovered completion, and the remaining
fault matrix are still required U3 evidence.

This boundary remains an internal `candidate`. U3 must still bind the repaired
production decision/effect stream into the compressed candidate evidence
protocol and satisfy production qualification before the catalog can promote
it or any mutator cutover can be claimed.

## Safety invariants

- Patrol is opt-in at the scheduler gate AND at config resolution: a missing patrol section, a missing `mode:`, `patrol.mode: off`, or `patrol.enabled: false` all leave patrol disabled and prevent daemon dispatch, and the daemon still requires `daemon.enabled`.
- Findings surface as PRs, and opened PRs enter `6-review` by default; patrol still never writes `1-inbox/` intake tasks.
- A new sweep scans the exact freshly fetched remote default without moving the operator's local branch; configured-remote fetch failure stops before mapper/reviewer work. PR creation separately re-fetches the default for structured fresh-base reproduction/root-cause proof, configured validation, and secret scanning, so an older pinned review snapshot cannot become an old-base patch.
- Synthetic `6-review` handoff requires exact hosted base/head identity plus a final live remote base/head check for both first attempts and retries; a stale-base or raced-base PR cannot create a patrol review task.
- A non-dry-run cycle requires at least one configured validation command before mapping, review, or state mutation. `--dry-run` remains review-only and bypasses that preflight.
- Each semantic root maps to at most one durable active lineage per target. Same-target terminal duplicates are suppressed; same-target active records are reused by shipping cycles without another finding file. A newer target may create a recurrence lineage, superseding older active evidence while keeping resolved/rejected history. An open PR still blocks additional variants from the same feature, and one feature normally supplies at most one fix per cycle.
- A failed patrol-to-review handoff is not treated as an active fingerprint state, so later patrol cycles can retry instead of losing the opened PR from the review queue; an exact existing synthetic task is reconciled instead of duplicated.
- Every mutating ordinary or architecture sink has one durable semantic intent, one process-and-thread sender lock, and canonical replay bytes. No lease expiry, heartbeat, or PID can authorize a competing sender. Exact absence authorizes redispatch only for the gateway-owned retry-safe local sink set; remote absence remains unresolved.
- Ordinary schedules, module hooks, and Architecture Patrol merged-PR jobs use canonical window/generation reservations and compacted high-water/floor fences. Concurrent retries reuse one reserved attempt; only a terminal prior attempt advances the generation, stale compacted generations fail closed, and finalized occurrences reject new effect dispatch.
- Manual/direct non-sequenced occurrences use a bounded exact retirement fence. Saturation retains the terminal occurrence instead of deleting its replay proof; it never authorizes duplicate work.
- Architecture `job`, `discovery`, and `action` transitions pass through `TransitionGateway`; it owns no files or retry state, and JobStore remains authoritative.
- Architecture captures bind the full `project_id`, `name`, and `repository`
  descriptor to the exact registered project. The manifest registration and PR
  URL still form the immutable source and trigger provenance; a missing,
  drifted, or legacy partial project binding cannot be reserved, reused, or
  finalized.
- Active occurrence recovery uses the bounded `recovery-index.json` locator.
  Reservation publishes membership before its occurrence record, retirement
  removes membership only after the record is inactive, and crash recovery
  performs at most one bounded authoritative scan to repair a missing,
  malformed, stale, or dirty index. Idle ticks never scan retained terminal
  history.
- A daemon-launched `--job-manifest` discovery child reconstructs the same
  transition coordinator before reviewing. It never claims independently; its
  incremental checkpoints and heartbeats use only the exact PID/start-time and
  generation-bound token attached by the scheduler.
- JobStore runtime and child completion accept v3 only. Hive has no released-v2
  reader, converter, install-wide coordinator, package hook, or retry timer.
  A released `v2/jobs` directory blocks runtime until the operator runs
  `hive refactor-patrol-reset PROJECT --confirm` for that exact registered
  project. The command excludes daemon activation, drains the exact daemon
  generation, then takes the existing Patrol effect lock exclusively across
  its independent writer fence, opaque archive exchange, empty-v3 admission,
  and receipt. It never enumerates the archive and preserves every other v2
  owner plus the global terminal-proof catalog. A restarted daemon must publish
  generation-bound runtime readiness. Another OS user makes the same decision
  under their own profile; Hive never performs a privileged host sweep.
  Existing non-empty v3 state, malformed transaction evidence, or an
  unprovable writer fence fails closed instead of choosing which state to
  overwrite.
- Live v3 jobs, query sidecars, quarantine evidence, and action locks are
  accessed only through one descriptor-confined `JobStoreFiles` port. A
  store-wide admission lock enforces the 8,192-job bound before any new
  per-job lock or query membership is created.
- Cutover and rollback quiescence include ordinary active occurrences, architecture active occurrences, and incomplete v3 jobs before advancing an ownership epoch.
- Ordinary and architecture projection/recovery failures emit bounded project/occurrence/job diagnostics with retry count and next backoff time; durable outbox or exact-transition recovery remains pending while the scheduler backs off.
- Closed-unmerged patrol PRs become dismissals and are skipped on future cycles.
- Agent prompts treat findings and recommendations as data; validation commands come only from project config. Each admitted finding is bound to one configured validation key and the exact reviewed target SHA. Before the fixer agent starts, Hive checks out the fresh current base, runs that command as a clean baseline, and refuses a stale target, failing baseline, or baseline command that mutates the checkout.
- Review launches are admitted only with conservative initial-context headroom,
  use a bounded provider tool context, and stop after the completed artifact or
  four Claude turns; the structured parser still fails closed on malformed or
  incomplete output.

## Backlinks

- [[commands/patrol]]
- [[commands/refactor-patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[modules/worktree]]
- [[modules/agent]]
