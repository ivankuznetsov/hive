---
title: Hive::Patrol
type: module
source: lib/hive/patrol/, packaging/patrol_evidence/, test/e2e/lib/patrol_qualification.rb
created: 2026-05-28
updated: 2026-08-14
tags: [module, patrol, review, worktree, pr, codex]
---

**TLDR**: `Hive::Patrol::*` is the ordinary repository-patrol engine behind [[commands/patrol]]. It keeps clawpatch-style work units and audit state as plain JSON under `.hive-state/patrol/`, delegates review/fix reasoning to configured Hive agent profiles, records Patrol usage in `Hive::UsageDb`, validates fixes in isolated worktrees, opens PRs, and by default hands opened PRs into the normal `6-review` flow. The separately configured, post-merge Architecture Patrol lives under `Hive::RefactorPatrol::*`. They share one project-wide agent lock and one high per-agent runaway fuse, but not state, mapping, policy, or action ledgers; usage totals are telemetry rather than allowance.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Patrol::Mapper` | `lib/hive/patrol/mapper.rb` | Ordinary patrol enables the shared architecture capability: non-overlapping language-neutral source/manifest components with dependency-ranked context and subsystem tests, plus one primary review per command or grouped manifest-script contract. Command paths remain component context, not duplicate evidence anchors. Legacy route/package/monolithic-test slices remain available only to callers that omit that capability. A completed map is handed to `StateStore` as one retry-safe semantic batch instead of consuming one occurrence effect per feature. |
| `Hive::Patrol::SourceReader` | `lib/hive/patrol/source_reader.rb` | Shared root-confined, regular-file-only, 256 KiB bounded reader used by architecture mapping and review. It resolves tracked symlinks beneath the canonical project root and skips external/device targets before reading. |
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
| `Hive::Patrol::AgentLaunch` | `lib/hive/patrol/agent_launch.rb` | Builds the provider-specific patrol launch envelope shared by ordinary review and fix. Active exact or coarse `models:` routes win; otherwise a Claude-backed launch carries the project-wide `claude.model` / `claude.effort` pin instead of falling through to Claude Code's interactive default. Claude reserves 20,000 tokens for provider-owned initial context plus one conservative token per prompt byte, uses a verified minimal review/fix tool set, and caps reviews at four completed turns; the fourth is emergency JSON finalization only. |
| `Hive::Patrol::ReviewErrorDetails` | `lib/hive/patrol/review_error_details.rb` | Converts an agent resource-exhaustion result into the shared durable review-error detail envelope used by ordinary and architecture patrol. |
| `Hive::Patrol::TokenBudget` | `lib/hive/patrol/token_budget.rb` | Owns the project-keyed full-agent-lifetime lock, the single shared `max_tokens_per_agent` emergency fuse, and UsageDb telemetry for ordinary review/fix and architecture review/fix. Prompt plus provider initial context must fit the fuse. Usage recording failures warn and release the lock but never create a later admission quota. |
| `Hive::Patrol::Dismissals` | `lib/hive/patrol/dismissals.rb` | Reconciles closed-unmerged patrol PRs into `dismissed.json` so the same finding is not immediately re-filed. Retryable publication entries match only their exact receipted PR URL and remain retryable while that PR is open. |
| `Hive::Patrol::BaseStateStore` | `lib/hive/patrol/base_state_store.rb` | Shared JSON lifecycle for ordinary patrol and architecture patrol's legacy reporting state: directory creation, state/fingerprint/dismissal files, run artifacts, and tolerant reads. It delegates atomic replacement to `Hive::AtomicFile` while preserving the stores' prior no-fsync behavior. |
| `Hive::Patrol::StateStore` | `lib/hive/patrol/state_store.rb` | Defines the ordinary-patrol collections, is the sole ordinary `EffectGateway` composition root, and exposes the ordinary product recovery API over the shared occurrence journal. Its full-cycle lock is also the nonblocking daemon admission fence: recovery and reservation cannot adopt a manual worker's occurrence, while a manual mutating cycle refuses an already-reserved daemon occurrence. Read-only dry runs do not allocate journal occurrences. Feature maps use one digest-bound batch effect whose local writes can be reconciled or replayed after a partial failure, so repository size does not consume the occurrence effect budget. Fingerprint writes require the configured gateway and persist the exact canonical set/delete operation in the occurrence intent. Before any fingerprint read or suppression decision, recovery walks every recovery-active predecessor capture, reconciles or retry-safely redispatches that exact operation, and rejects multiple nonterminal predecessors for one fingerprint. It also projects typed publication outbox entries into one immutable fingerprint binding, writing the binding before tuple acknowledgement so crash-before-ack replay is an exact no-op. Fingerprints retain PR mapping only; the removed effect-intent maps are not a parallel retry authority. |
| `Hive::Modules::Migration::PatrolDecisionProjection` | `lib/hive/modules/migration/patrol_decision_projection.rb` | Strict shared value for the immutable selection result. Separate ordinary and architecture projectors validate their own input vocabularies before constructing it; terminal outcome and effect evidence are not selection fields. |
| `Hive::Modules::Migration::OccurrenceJournal` | `lib/hive/modules/migration/occurrence_journal.rb` | Public durable-occurrence facade. It composes a pure `OccurrenceRecordValidator`, one `OccurrenceRecordStore` lock/read/write owner, bounded `OccurrenceJournalState`, typed `OccurrenceOutbox`, `OccurrenceEffects`, stable sender locks, and durable attempt allocation; the final capture must retain the exact selection, reject nonterminal effects, and bind exactly the terminal receipt ids. Receipt and publication entries may share an id, so acknowledgement is bound to the exact `(kind, id, digest)` tuple. `StateStore` and `JobStore` remain the separate product-facing recovery authorities. |
| `Hive::Modules::Migration::OccurrenceJournalState` | `lib/hive/modules/migration/occurrence_journal_state.rb` | One bounded 64 KiB coordination cell per product journal. It persists compacted schedule high-water/floor fences, a bounded exact fence for non-sequenced terminal captures, and normalized restart-safe recovery backoff; it contains no effect, outbox, or product work state. |
| `Hive::Modules::Migration::OccurrenceRecoveryIndex` | `lib/hive/modules/migration/occurrence_recovery_index.rb` | Descriptor-confined, bounded locator for exact reserved or projection-pending occurrence ids. Its generation is fenced by `OccurrenceJournalState`; missing, malformed, stale, or dirty state receives one bounded authoritative-record repair. It never authorizes work or stores effect bytes. |
| `Hive::Modules::Migration::EffectDelivery` | `lib/hive/modules/migration/effect_delivery.rb` | Product-neutral composition facade shared by the two direct-`Object` gateways. `EffectAdmission` owns live owner/config/module-generation/grant/claim policy, `EffectSender` owns stable-lock/fence/reconciliation transitions, and `EffectReceiptLedger` owns terminal replay and observational receipt projection. The occurrence store, not the sender or ledger, mints authoritative receipt bytes. Dependencies point toward the injected product store; none of these collaborators owns persistence. |
| `Hive::Patrol::EffectGateway` | `lib/hive/patrol/effect_gateway.rb` | Thin ordinary-patrol product port over `EffectDelivery`. It preserves the ordinary `perform!` and reconcile-only adoption API while authorizing ordinary state, finding, attempt, branch, PR, and review-handoff sinks. |
| `Hive::RefactorPatrol::EffectGateway` | `lib/hive/refactor_patrol/effect_gateway.rb` | Thin Architecture Patrol product port over `EffectDelivery`. It retains architecture claim and `NotDelivered` policy while action claim generation fences authorization but remains outside semantic remote-effect identity. |
| `Hive::RefactorPatrol::TransitionGateway` | `lib/hive/refactor_patrol/transition_gateway.rb` | Non-persistent product port that routes architecture `job`, `discovery`, and `action` transitions through the architecture gateway. It writes only by invoking a JobStore transition and replays JobStore after duplicate delivery. |
| `Hive::RefactorPatrol::ArchitectureOccurrenceStore` | `lib/hive/refactor_patrol/architecture_occurrence_store.rb` | JobStore's product adapter over `OccurrenceJournal`. It resolves the exact current `occurrence_id` held by the v4 job aggregate, validates an exact next-generation successor against its predecessor, and delegates all occurrence/effect state; there is no sidecar binding or fallback index. Recovery takes one validated effect snapshot for the current segment and ignores already-finalized predecessor transitions. |
| `Hive::RefactorPatrol::JobStore` | `lib/hive/refactor_patrol/job_store.rb` | Architecture Patrol's current-only v4 aggregate and product recovery authority. V3 bytes remain opaque and the first current mutation starts a fresh v4 store. Each job owns one immutable intake transition and one current occurrence pointer; the pointer can advance only through the fenced rollover write after its predecessor is terminal. Finished claim and diagnostic history retains historical occurrence ids, while active claims must match the current segment. Before a saturated segment rolls, JobStore may terminalize only a discovery claim whose recorded process identity the injected resolver proves gone; a live or unresolved claim remains fenced even after expiry. A prepared local effect with no authoritative aggregate transition is then denied in place as abandoned, including when restart recovery resumes an interrupted rollover, while a recorded or dispatch-uncertain effect still blocks rollover. These recovery writes consume no new occurrence effect, so a full journal cannot deadlock its own rollover. Action scheduling preserves the runner's fix-before-related-issue dependency, so a queued fallback issue cannot bypass its same-family fix cooldown. |
| `Hive::RefactorPatrol::ArchitectureIntakeTransitions` | `lib/hive/refactor_patrol/architecture_intake_transitions.rb` | Shared command/daemon coordinator for manifest occurrence reservation, exact enqueue reconciliation, and transition identity. A duplicate manifest whose authoritative job already matches returns that aggregate directly, including after occurrence rollover, instead of consuming another transition cell. Callers retain policy and cadence; this collaborator adds no persistence of its own. |
| `Hive::RefactorPatrol::ActionTransitions` | `lib/hive/refactor_patrol/action_transitions.rb` | Facade used by `ActionRunner`: claim-scoped CAS/reconcile/receipt operations and job-level plan/link/block transitions live in separate coordinators over one immutable transition context. `ActionRunner` retains thesis, policy, fixer, publication, and issue decisions; its action transitions define the shared one-hour cooldown used by both runner and scheduler action failures so a persistent local/provider fault or per-agent token fuse cannot hot-loop claim/release evidence. |
| `Hive::RefactorPatrol::DiscoveryCapacity` | `lib/hive/refactor_patrol/discovery_capacity.rb` | Defines the twelve-feature discovery slice and its fourteen-effect worst-case journal cost without loading command or transition dependencies. Scheduler admission uses it to roll before launch; manual `--pr` discovery waits for that automatic rollover instead of starting a claim that cannot finish. |
| `Hive::RefactorPatrol::ClaimLivenessResolver` | `lib/hive/refactor_patrol/claim_liveness_resolver.rb` | Read-only process-identity probe shared by heartbeat, restart admission, and capacity rollover. It distinguishes a gone/reused owner from a matching live owner or child but never sends a signal. A restarted daemon may surface a proven-dead claim before its lease expires, then rechecks the claim under the normal CAS before a new generation; a live or uninspectable owner remains fenced. The separate `ProcessGroupResolver` remains the explicitly terminating expired-claim recovery path. |
| `Hive::RefactorPatrol::DiscoveryTransitions` | `lib/hive/refactor_patrol/discovery_transitions.rb` | Facade used by `RefactorPatrolScheduler` and its command child: discovery claim/checkpoint/release and diagnostic block transitions live in separate coordinators. The scheduler claims and attaches the exact child process; `--job-manifest` reconstructs the non-claiming command-side coordinator before incrementally checkpointing through that attached token. `ArchitectureOccurrenceLifecycle` alone reserves/finalizes occurrences and recovers capture/event/receipt projections; the scheduler retains cadence, candidate selection, spawn, and envelope handling. |
| `Hive::RefactorPatrol::ClaimMaintenanceTransitions` | `lib/hive/refactor_patrol/claim_maintenance_transitions.rb` | Narrow non-outcome port for generation-fenced child-process attachment and discovery/action heartbeat renewal. Command and scheduler roots cannot call those JobStore mutators directly. |
| `Hive::Modules::Migration::PatrolEvidence` | `lib/hive/modules/migration/patrol_evidence.rb` | Strict immutable ordinary/architecture capture, intent, and receipt values shared only as an observation protocol. `EvidenceStore` appends canonical records, maintains bounded occurrence/intent indices, and repairs them through portable lexicographic pages whose cursors freeze one high-water inventory plus an order-independent filename fingerprint. `ManagedDirectory` rejects linked managed components and descriptor-binds its bounded reads, locks, and atomic writes; evidence remains observation-only and has no mutation or recovery authority. |
| `Hive::Modules::Migration::PatrolEvidenceReceipt` | `lib/hive/modules/migration/patrol_evidence_receipt.rb` | Canonical immutable U3 qualification input binding one run, candidate, catalogue/source/manifest/configuration/scenario set, repository change window, U2 capture, exact terminal effect receipts, fault steps, artifacts, reviewer, and timestamps. Receipt construction bounds collections before mapping, rejects cross-occurrence effects, rejects non-string or invalid-UTF-8 string fields with `Hive::ConfigError`, and requires captures to bind exactly their committed or reconciled legacy receipts; its JSON schema composes the strict U2 capture, projection, and effect schemas. |
| `Hive::Modules::Migration::PatrolEvidenceVerifier` | `lib/hive/modules/migration/patrol_evidence_verifier.rb` | Pure verifier that re-parses a receipt and compares every authority-sensitive binding, including the exact receipt identity, complete fault-step set, and each typed artifact with caller-supplied expected values. Expected bindings retain their declared JSON types and are never string-coerced. It never derives expected project, candidate, scenario, artifact, capture, epoch, projection, or effect identities from the receipt it is checking, and only the verifier can construct its verified token. |
| `Hive::Modules::Migration::PatrolEffectIndex` | `lib/hive/modules/migration/patrol_effect_index.rb` | Bounded immutable run-wide projection over verified effect receipts. Exact receipt replay is counted but idempotent. Distinct committed/reconciled externally observable effects that collide by intent, idempotency key, or semantic identity become qualification findings; local `job`, `discovery`, and `action` JobStore transitions are keyed only by intent and idempotency so a fenced recovery generation may repeat a local target/scope without creating a false semantic collision. `attempted` and `unknown` effects remain visible and block qualification, while denied, known-not-sent, and failed receipts remain non-effects. |
| `Hive::Modules::Migration::PatrolQualification` | `lib/hive/modules/migration/patrol_qualification.rb` | Pure immutable qualification value. Each module requires at least ten unique comparable trigger/repository/SHA/change-window decision identities spanning at least two decision classes, repository SHAs, and change windows under one configuration digest; timestamp, fault-step, artifact, or exact receipt replay cannot inflate the count, while decision/effect replay counts remain visible. The qualification binds the earliest capture time derived from verified receipts, so later report recovery cannot relabel pre-contradiction observations as fresh. One capture or occurrence cannot be rewrapped into conflicting repository/window decisions. Terminal non-legacy/shadow effects, unsettled effects, duplicate identities, mixed run bindings, and unsuperseded contradictions fail closed. |
| `Hive::Modules::Migration::ReportProjection` | `lib/hive/modules/migration/report_projection.rb` | Pure report-v2 projection over exactly `deterministic` and `installed_live` qualification lanes. Both lanes must bind the same candidate, catalogue, source, manifest, scenario, and configuration set. Persistence admits only monotonic successor reports: a missing lane may be added; an `evidence_required` lane may advance through a strict same-run receipt superset or a disjoint fresh run; a qualified lane may be exactly invalidated; and recovery from an invalidated report requires new run identities, disjoint receipt sets, and evidence beginning after the latest contradiction in both lanes. Successors preserve migration provenance and every transition remains digest-CAS guarded. The v2 JSON schema accepts both strict persisted projections and the command's shared current-version error envelope. An explicitly migrated empty report records `evidence_required` rather than qualification. |
| `Hive::Modules::Migration::ReportMigration` | `lib/hive/modules/migration/report_migration.rb` | One-off project-local report converter over the existing `Report` storage facade. It accepts the complete released v1 success, null-configuration, and error-envelope shapes; preserves exact source bytes in a fixed archive; validates source/archive/receipt linkage on read-only probes; repairs a missing receipt only for the initial unsuperseded migration projection under the existing exclusive lock; rejects missing provenance after any successor; binds that immutable receipt to migration provenance rather than mutable later report bytes; uses digest CAS in both directions; and owns no cutover, rollback, retry, or effect recovery. |

`Hive::Modules::Migration::Patrols.deterministic_receipt_for!` is the bounded
U3b receipt-construction seam. Its exact module/trigger-id selector must resolve
one comparable terminal shadow record while the exclusive migration lock is held;
the record supplies the capture, decision projection, and complete
observational effect set, while caller metadata remains subject to the receipt
protocol's configuration checks and must exactly match the nonempty repository
target captured by the product scheduler. Both Patrol products use the same
host-qualified `host/owner/name` target: ordinary Patrol derives it from the
registration and Architecture Patrol binds the manifest repository to its PR
URL host. Missing, ambiguous,
nonterminal, divergent, duplicate-effect, configuration-mismatched, or
identity-mismatched evidence fails closed.

New Architecture Patrol captures require the host-qualified target. The
occurrence store accepts an older owner/name-only project only when the exact
same immutable capture is already durable (or its job pointer already binds
that occurrence); replay compatibility cannot create new qualification
evidence. The deterministic receipt facade requires an exact
`host/owner/name` target and rejects owner/name-only replay even when caller
metadata repeats that legacy value.

`Hive::Modules::Migration::Patrols.admit_deterministic_qualification!` remains
the single production admission path for U3b evidence. It accepts bounded raw
receipt documents plus independently computed expected bindings, constructs no
scenario or collector, and owns only verification, deterministic qualification,
and digest-CAS report-v2 merge.

The internal `hive module migration deterministic-receipt` and
`deterministic-qualification` actions expose only those two facades. They read
one exact-key, strict UTF-8 JSON object from bounded stdin; qualification also
requires `--yes`. They accept no request path and add no runner, store, or
cutover authority. Their command layer loads only shared lightweight errors,
not the module lifecycle/store base.

The separately invoked reduced installed/live smoke has exactly five
packaging owners: `Result` owns the canonical bounded schema and claim fences;
`Candidate` owns streamed archive and exact installed closure/module identity;
`Sandbox` owns the fixed digest-pinned container and whole-process custody;
`ProviderProbe` owns one closed host-side authenticated transport check; and
`Runner` owns manual authority, composition, expected-byte publication, and
explicit retention cleanup. The existing E2E controller supplies only the
bounded read-only `external_smoke` operation. The sandbox mounts that exact
trusted controller script and its secret-pattern support as separate read-only
files plus a separately admitted read-only candidate source tree; candidate
builds run only from a writable copy. Installed gemspecs remain opaque hashed
files and are never evaluated by the trusted controller. Runner binds one
canonical one-hour authorization to the controller/candidate/image/invocation,
the live registered project repository/HEAD/state tree, and the observation
file, then rejects retained authorization replay. Transient archives, source,
container custody, and controller scratch data stay outside the retained
result-only evidence directory. The sandbox uses one hashed engine executable
and a closed environment for probe, execution, and ID-owned teardown; it never
loads the candidate's controller copy or mounts the controller checkout. This path does not construct
`PatrolQualification`, write report v2's `installed_live` lane, schedule or
recover Patrol work, admit evidence for an operator, or authorize cutover.

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
.hive-state/module-runtime/migration/
  .mutation.lock                 # descriptor-confined Report/Patrols authority
  report.json                    # strict report-v2 projection at runtime
  report.v1.archive.json         # exact one-off source bytes
  report.migration.json          # immutable archive/projection provenance
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
merge, and requires every architectural thesis to receive a durable `fix`,
`discuss`, or `dismiss` route before any separately authorized action.
Architecture Patrol fetches and pins an exact committed default-branch SHA, then
runs mapper and reviewer source reads from an ephemeral detached,
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
architecture keeps six plus six for component context. Context and test paths are not preloaded into the ordinary review
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
`.hive-state/refactor_patrol/v4/`. V3 JobStore bytes remain opaque; the first
current mutation starts an empty v4 store without a compatibility reader.
`Hive::Daemon::PatrolArbiter` is the only shared
orchestration seam: it alternates ready work under the project's
`daemon.max_concurrent_patrol_scans` capacity. Enabling architecture discovery
does not enable ordinary patrol or auto-fixing. Deduplicated GitHub issues are
its default human review surface, with an explicit
`issue_filing.enabled: false` opt-out; neither system can consume the other's
state as proof of completion.

## Daemon triggers

Patrol is **opt-in**. A project with **no patrol section at all** (or a patrol section that omits `mode:`) resolves to `enabled: false` — [[modules/config]] only derives mode knobs when `mode:` is **explicitly present** in the raw config. `medium` is the default offered by the `hive init` *prompt* (which writes an explicit `mode: "medium"` into the rendered template), never a config-resolution default, so legacy projects without a patrol block are never silently enabled.

Repository patrol is also coding-workflow-only. Ordinary scheduling, merged-PR
architecture intake, architecture discovery/action reservation, and direct
execution all require the project's resolved `default_workflow` to be
`coding`; a stale or hand-edited enable flag cannot launch either patrol for
Writing, Architecture, Bench, or another non-coding default. Architecture
Patrol's read-only `--list` and `--show` queries remain available so prior
evidence is not hidden, and ordinary recovery can finish projecting an already
reserved receipt without starting a new repository scan.

`patrol.mode` controls cadence only; `off` disables scheduling. Every Patrol
child uses the same deliberately high `max_tokens_per_agent` fuse and one
project-wide advisory lock. There are no cycle/day token quotas, launch-count
quotas, multipliers, or Patrol-specific native USD clamp. Each launch still
requires its prompt plus provider-owned initial context to fit the fuse;
otherwise `TokenBudget#acquire` returns `insufficient_launch_headroom` without
spawning. UsageDb records measured and unmetered work as telemetry only.

Ordinary review batching is bounded directly by `max_features_per_cycle`, and
fixes by `max_fix_attempts_per_cycle` and `max_prs_per_cycle`. A structured
per-agent token-limit result ends the current ordinary cycle; Architecture
Patrol retains its checkpoint/receipts and uses a fixed one-hour retry for
structured `token_limit`, `turn_limit`, or project-lock `agent_in_flight`
discovery results. Lock contention therefore cannot consume a new journal
claim every minute while ordinary Patrol owns the shared agent slot. Other
retryable discovery uses 60 seconds, while actions use the shared one-hour cooldown. When
a later review fails, the SHA-bound cursor
advances past only the proven-clean prefix; the failed feature and remaining
suffix stay pinned for retry.

Architecture discovery leases are crash fences, not mandatory restart delays.
Candidate selection read-only probes an attached worker's PID, process start
time, and process group. When that exact process is already gone, the new
daemon may supersede the abandoned generation and resume immediately even if
its two-hour lease has not expired. A matching live worker, missing identity,
or failed probe remains fenced; dry runs never perform the probe or mutation.

`Hive::Daemon::PatrolScheduler` still consumes the lower-level `patrol.trigger`
modes. `continuous` dispatches when either the default branch SHA changed or
`poll_interval_sec` has elapsed, allowing patrol to keep reviewing existing
feature slices between infrequent merges. A not-yet-due timer wakes at the
exact `last_run_at + poll_interval_sec` deadline; daemon startup does not push
that deadline out by another full interval. A due candidate consumes its
cadence slot only when reservation succeeds, so ordinary Patrol remains
eligible on the next daemon tick when the shared arbiter gives the current
slot to Architecture Patrol. Each cycle
persists a SHA-bound feature cursor; `last_scanned_sha` advances only after the
full mapped sweep succeeds. `new_commits` therefore keeps dispatching
successive batches until that sweep completes. `timer` dispatches solely from
`last_run_at` age.

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
The U3a report-v2 projection is evidence-only: current Patrol cutover rejects
it with a typed operator-boundary error until a separately authorized lifecycle
slice owns cutover. Interrupted stable upgrades restore both stable admissions
before normal scheduling resumes.

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
occurrence. Missing, malformed, foreign, provisional, provenance-only, or
schema-import captures remain non-comparable. Module-native cron targets are
suppressed while legacy or shadow owns either product, preventing a second
schedule producer.

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

This boundary remains an internal `candidate`. The opt-in reduced U3b successor
under `test/e2e/` can take a prepared disposable project's real persisted
ordinary and Architecture Patrol shadow records through an archived, privately
installed candidate's internal receipt and qualification process facade. It neither creates
those scheduler records nor supplies independent controls: catalogue and
controller remain same-head test assets. The controller pins and archives the
candidate before loading its catalogue, digest-binds its executing source to
the archived copy, closes ambient Git configuration, and rechecks candidate
HEAD and cleanliness after capture. Shadow/report input uses descriptor-bound
no-follow reads, count and byte ceilings, and the campaign's monotonic deadline;
owned process groups are reaped even after a terminal leader result. Retained
evidence redacts and scans every string through `Hive::SecretPatterns`, and
typed process outcomes validate status according to their exact kind. Interior atomic crash contracts stay
owned by their exact focused tests. Full independent U3b qualification,
installed/live U3c evidence, catalogue promotion, and mutator cutover therefore
remain unproven.

## Safety invariants

- Patrol is opt-in at the scheduler gate AND at config resolution: a missing patrol section, a missing `mode:`, `patrol.mode: off`, or `patrol.enabled: false` all leave patrol disabled and prevent daemon dispatch, and the daemon still requires `daemon.enabled`.
- Findings surface as PRs, and opened PRs enter `6-review` by default; patrol still never writes `1-inbox/` intake tasks.
- A new sweep scans the exact freshly fetched remote default without moving the operator's local branch; configured-remote fetch failure stops before mapper/reviewer work. PR creation separately re-fetches the default for structured fresh-base reproduction/root-cause proof, configured validation, and secret scanning, so an older pinned review snapshot cannot become an old-base patch.
- Synthetic `6-review` handoff requires exact hosted base/head identity plus a final live remote base/head check for both first attempts and retries; a stale-base or raced-base PR cannot create a patrol review task.
- A non-dry-run cycle requires at least one configured validation command before mapping, review, or state mutation. `--dry-run` remains review-only and bypasses that preflight.
- Each semantic root maps to at most one durable active lineage per target. Same-target terminal duplicates are suppressed; shipping cycles rank the durable active backlog with newly reviewed findings, so a per-feature skip or rotating feature cursor cannot strand retryable work. A newer target may create a recurrence lineage, superseding older active evidence while keeping resolved/rejected history. An open PR still blocks additional variants from the same feature, and one feature normally supplies at most one fix per cycle.
- A failed patrol-to-review handoff is not treated as an active fingerprint state, so later patrol cycles can retry instead of losing the opened PR from the review queue; an exact existing synthetic task is reconciled instead of duplicated.
- Every mutating ordinary or architecture sink has one durable semantic intent, one process-and-thread sender lock, and canonical replay bytes. No lease expiry, heartbeat, or PID can authorize a competing sender. Exact absence authorizes redispatch only for the gateway-owned retry-safe local sink set; remote absence remains unresolved.
- Ordinary schedules, module hooks, and Architecture Patrol merged-PR jobs use canonical window/generation reservations and compacted high-water/floor fences. Concurrent retries reuse one reserved attempt; only a terminal prior attempt advances the generation, stale compacted generations fail closed, and finalized occurrences reject new effect dispatch.
- Manual/direct non-sequenced occurrences use a bounded exact retirement fence. Saturation retains the terminal occurrence instead of deleting its replay proof; it never authorizes duplicate work.
- Architecture `job`, `discovery`, and `action` transitions pass through `TransitionGateway`; it owns no files or retry state, and JobStore remains authoritative.
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
- JobStore runtime and child completion accept v4 only. Construction and
  read-only queries do not create state; the first mutation lazily creates
  only v4. Hive has no v3 reader, probe, converter, reset command, archive
  layer, package hook, or retry timer. V3 bytes are ignored while every other
  live reconciler owner and the global terminal-proof catalog remain unchanged.
  Malformed v4 job, occurrence, or query-index evidence fails closed instead
  of being rewritten.
- Live v4 jobs, query sidecars, quarantine evidence, and action locks are
  accessed only through one descriptor-confined `JobStoreFiles` port. A
  store-wide admission lock enforces the 8,192-job bound before any new
  per-job lock or query membership is created. Inventory accepts the exact
  writer-owned `.JOB.json.tmp.PID.HEX` name only while it is a regular file or
  has vanished during the atomic rename; every other unknown or non-regular
  entry still fails closed, and special-file probes are nonblocking. The
  next holder of a job's exclusive lock removes any temporary left by its
  previous writer, so the bounded inventory can reserve exactly one temporary
  slot per admitted job. A concurrent job write therefore cannot be
  misreported as unresolved repository identity, including at store capacity.
- Cutover and rollback quiescence include ordinary active occurrences, architecture active occurrences, and incomplete v4 jobs before advancing an ownership epoch.
- Ordinary and architecture projection/recovery failures emit bounded project/occurrence/job diagnostics with retry count and next backoff time; durable outbox or exact-transition recovery remains pending while the scheduler backs off.
- Closed-unmerged patrol PRs become dismissals and are skipped on future cycles.
- Agent prompts treat findings and recommendations as data; validation commands come only from project config. Each admitted finding retains its exact reviewed target SHA as provenance. Before the fixer agent starts, Hive checks out the fresh current base and, when that SHA has advanced, loads each bounded cited line from the reviewed commit and revalidates that full line there. An unchanged line or one uniquely relocated byte-for-byte continues; missing, changed, oversized, or ambiguous evidence becomes a fail-closed `stale_evidence` outcome. Hive then runs the configured command as a clean baseline and refuses a failing baseline or one that mutates the checkout.
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
