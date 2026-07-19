---
title: hive refactor-patrol
type: command
source: lib/hive/commands/refactor_patrol.rb, lib/hive/refactor_patrol/*
created: 2026-07-02
updated: 2026-07-19
tags: [command, refactor-patrol, architecture, json, daemon]
---

**TLDR**: `hive refactor-patrol` is Hive's language-neutral architecture
patrol. The original on-demand v1 report remains available, while merged-PR
mode emits a durable v2 lifecycle: immutable PR scope, read-only discovery,
exhaustive dispositions, and separately authorized isolated fixes or
deduplicated issues. It is not Ruby- or Hive-specific: discovery maps generic
repositories and unfamiliar source languages. Automatic mutation is narrower
by design; a language needs a certified public-contract guard or its thesis
stays report/issue-only with `public_contract_safety_unavailable`.

## Usage

```bash
# Legacy on-demand report (v1)
hive refactor-patrol my-project --json
hive refactor-patrol my-project --feature route-home --changed-since origin/main

# Explicit merged-PR replay (v2)
hive refactor-patrol my-project --pr 123 --json
hive refactor-patrol my-project --pr https://github.com/acme/app/pull/123 --json

# Daemon/internal immutable-manifest phases
hive refactor-patrol my-project --job-manifest PATH --json
hive refactor-patrol my-project --job-manifest PATH --actions --json
# The daemon also supplies an internal --result-file under v2/results/.

# Read-only durable job inspection
hive refactor-patrol my-project --list
hive refactor-patrol my-project --list --limit 50 --cursor CURSOR
hive refactor-patrol my-project --show JOB_ID
hive refactor-patrol my-project --show JOB_ID --json
hive refactor-patrol my-project --show JOB_ID --full --json
```

Fresh terminal and web init recommend discovery (`refactor_patrol.enabled:
true`) with a default-yes choice. Missing configuration in an existing project
still resolves to false. The two external-effect gates never inherit discovery
consent and default off. Fresh headless init can resolve the discovery choice
before any project-state write with `hive init --refactor-patrol` or
`hive init --no-refactor-patrol`; omitting both keeps the enabled default.

```yaml
refactor_patrol:
  enabled: true
  # Proposal-specific leverage below this floor is retained as an audited
  # suppression, not ranked or acted on.
  min_leverage_score: 0.25
  max_theses_per_feature: 1
  auto_fix:
    enabled: false
    agent: codex
  issue_filing:
    enabled: false
    min_leverage_score: 0.25
  min_confidence: medium
  commands:
    docs: null
    # Optional project-owned compatibility check for source/public surfaces.
    public_contract: null
    test: bin/test
```

## Discovery modes

The legacy no-PR mode keeps the v1 reporting/state contract and accepts
`--feature`, `--entrypoint`, `--path`, and `--changed-since`. It does not run
the v2 action ledger.

`--pr` and `--job-manifest` are v2 modes. They require JSON, reject legacy
scope hints, select mapped features only from the immutable changed-path/status
manifest, and pin a freshly fetched committed default-branch `analysis_sha`
that contains the merge. Discovery materializes that commit as a detached,
clean, exact worktree under the configured worktree root. Mapper, leverage, and
reviewer source reads all use that tree, while durable job state remains under
the registered project's `.hive-state`. The operator's current branch and
uncommitted edits are therefore outside the analysis boundary. The daemon
consumes only the write-once manifest published by merge intake; it never
re-fetches mutable PR metadata during discovery.

On partial-job resume, the durable `analysis_sha` must be a full 40- or
64-character hexadecimal Git object ID. Commit resolution fences option
parsing and revalidates Git's returned object ID before materializing a tree.
An explicit replay of a terminal job creates its new occurrence before this
pin step, so the replay samples the current committed default branch while an
incomplete retry continues to reuse its original durable SHA. PR dry runs use
an invocation-unique analysis-worktree key and therefore cannot reuse or
remove a same-job daemon worker's tree. If an interrupted removal leaves only
stale Git worktree administration, the next materialization prunes that orphan
record and retries without operator repair.

Discovery requires Claude's read-only tool scope plus its verified
`--safe-mode` capability, so project customizations cannot run before the
read-only boundary is established; an older or overridden Claude binary that
does not advertise the flag fails closed. Hive validates the analysis worktree
before each feature checkpoint and again before completion. A reviewer that
dirties the detached source tree makes the command fail, removes the ephemeral
tree, and releases its discovery claim as `command_error`. Every thesis appears exactly once
as accepted, flagged, or suppressed. Complete zero-result runs use
`no_mapped_slice`, `no_theses`, or `all_suppressed`; malformed or partial
reviewer results remain retryable and do not checkpoint completion.
Completed feature slices and their exhaustive dispositions are checkpointed
independently; a retry reviews only incomplete slices and cannot rewrite a
previously completed slice.

The architecture mapper groups bounded components rather than manufacturing a
feature per file. It recognizes common language extensions, build files,
package roots, infrastructure layouts, extensionless shebang scripts, and
previously unknown text-source extensions; each package manifest owns a small
dedicated slice instead of expanding every source feature. Lightweight generic
and ecosystem-specific import resolution builds a source-only dependency graph
across slash-, dot-, backslash-, and namespace-style references. Tests, docs,
assets, generated artifacts, fixture/test manifests, and mapper chunk boundaries
do not inflate fan-in/coupling scores or consume reviewer slices.
All outer semantic mapping, architecture mapping, and leverage content reads go
through one root-confined source reader before a path can enter a reviewer
slice: tracked symlinks may resolve only to regular files beneath the real
project root, device/FIFO-like targets are skipped, and each UTF-8-scrubbed read
is capped at 256 KiB. Deleted or renamed-away documentation paths may remain as
non-readable historical scope, but an existing unsafe documentation symlink is
never handed to the reviewer. This keeps an unfamiliar or hostile repository
from escaping the checkout or turning discovery into an unbounded read.

Documentation mapping is a refactor-patrol-only capability. When appropriate,
it maps bounded root-document, `docs/`, wiki, ADR, and decision slices. Compiled
wiki logs, raw notes, caches, generated content, and `.hive-state` do not become
one broad documentation feature. Ordinary `hive patrol` mapping is unchanged.

`max_theses_per_run` is a strict run-wide reviewer-output budget, not a
per-feature allowance. The per-feature default is one thesis, explicitly a
ceiling rather than a quota. A slice whose complete measured hotspot cannot
possibly reach `min_leverage_score`, even with 100% relief, completes without
launching an agent. `max_review_seconds_per_run` (default 3600) is the
matching absolute monotonic wall-clock budget: each feature spawn receives only
the smaller of its configured patrol timeout and the whole-run time remaining.
Once either budget is exhausted, later slices stay incomplete for a future
resume instead of multiplying one agent timeout by every mapped feature.
Before each architecture review or fix spawn, the shared project patrol budget
also checks the selected `patrol.mode` token and launch ceilings. Architecture
stages default to 2x the mode's per-cycle token/launch limits and per-agent
streamed-token limit so broad boundary analysis is not constrained like a
single ordinary slice; the native budget-equivalent guard and project/day token
and launch ceilings stay shared.
Usage is attributed to the TUI patrol row; absent provider counts are retained
as unmetered launches and still consume quota. Budget exhaustion is an ordinary
retryable incomplete result, so discovery checkpoints completed slices and
actions retain their exact durable receipts rather than starting new work. PR
discovery bounds each command to the tighter remaining architecture-cycle or
shared UTC-day launch headroom. It stops after the first failed feature and
leaves later slices unattempted rather than manufacturing one failure per
slice. A fully reviewed bounded batch returns clean partial progress: completed
feature results are checkpointed, `complete` stays false, and the next command
resumes the untouched suffix without exposing ordinary scheduling as a review
error. When every reported error is a shared daily token or launch limit,
including positive daily token headroom too small for the next initial context,
the daemon backs the job off until the next UTC day instead of retrying it every
minute.
The read-only runner accepts either bare JSON or one whole-message `json` code
fence, normalizes the accepted object into `theses.json`, and retains the exact
provider response as `final-message.txt` in the feature run directory for
quality audits. Real PR-mode run directories are durable and include a
`review-context.json` binding the artifact to its job, analysis SHA, source PR,
and feature; only an explicit `--dry-run` uses ephemeral scratch space.
Surrounding prose, malformed
envelopes, null/scalar items, and
schema-invalid records remain review errors rather than successful zero-result
scans. Evidence is also checked against the pinned checkout's real,
root-confined, 256 KiB-bounded bytes: cited
files must exist, line anchors must be in range within that inspection window,
and snippets must occur exactly within it when present. One unverified citation
makes the thesis inadmissible. Proposal
leverage is derived from measured hotspot signals and model-explained relief.
The reviewer requires evidence of a current consequence rather than hypothetical
drift and rejects extra helpers/taxonomies that do not delete an ownership
decision or dependency direction. The default `min_leverage_score: 0.25`
classifies any residual low-value proposal as a persisted suppression: it stays
auditable but is absent from ranked/flagged findings and cannot trigger action.
If architecture mapping fails, leverage
retains a bounded `measurement.status: incomplete` diagnostic instead of
presenting its graceful zeroes as real measurements; affected theses remain
visible but are inadmissible for automatic action.

## Durable post-merge lifecycle

`Hive::Daemon::RefactorPatrolMergeReconciler` ingests both Hive finalize
observations and paginated GitHub catch-up into one occurrence identity:
registration, canonical repository, PR number, and merge SHA. First enablement
seeds a current baseline rather than importing history. Catch-up and individual
PR resolution bind GitHub calls and returned PR URLs to the exact host and
repository resolved from the registered checkout. The reconciler's v2
checkpoint separately binds registration, host, repository, and default branch;
unsupported/corrupt checkpoints or identity changes are quarantined and block
instead of silently rebaselining. Each manifest records the source URL and
repository, base and merge SHAs, merged time, complete file statuses/renames,
changed paths, and checksum before its job is runnable.

Catch-up is incremental and restart-safe without changing that authoritative
`reconciler.json` v2 checkpoint. A separate identity-fenced
`reconciler-progress.json` v1 sidecar binds registration, host, repository,
default branch, and the SHA-256 fingerprint of the base checkpoint. It records
one fixed overlap window (including its upper bound), the first page's result
count, the next GitHub page plus accumulated merge identities, then the next
manifest intake item plus already-enqueued PRs. A count or terminal traversal
change restarts at page one without moving that upper bound. Each origin
identity lookup, page, finalize-watcher PR-state poll, or hydration request
receives the remaining slice of one absolute monotonic tick budget shared with
exact-PR hydration later in that dispatcher tick. When
the budget is spent, watcher poll/intake stops the batch and retries next tick
without counting the deferral as a GitHub failure; a hanging state-poll
subprocess is terminated and follows ordinary watcher backoff. Partial projects
and the starting project rotate fairly so one slow repository cannot stall the
daemon. Real
GitHub failures persist jittered, capped exponential retry state from the
observed failure time, and that state survives daemon restart.

Sidecar and checkpoint replacements are atomic and directory-fsynced. A
completed scan writes the v2 checkpoint before unlinking and fsyncing the
sidecar. If a crash leaves the old sidecar after that checkpoint write, its base
fingerprint is stale and the next tick removes it. Earlier crashes resume the
page/intake cursor; write-once manifest/job intake makes replay idempotent.
Malformed or identity-drifted progress is quarantined and blocks.

The v2 job lifecycle is `queued → analyzing → classified → acting → complete`.
Discovery and actions use generation-fenced claims renewed by exact
PID/process-start heartbeats; workers without verifiable process identity do
not claim work. `JobStore` remains the sole aggregate lock/read/write facade,
but delegates deterministic responsibilities to three collaborators:
`JobRecordValidator` validates complete records and monotonic transitions,
`ClaimTransitions` constructs, renews, and finishes in-memory discovery/action
claims, and `JobIndexes` projects rebuildable fingerprint/action indexes from
terminal aggregates. None of those collaborators persists independently.
`PatrolArbiter` gives
ordinary and architecture scans the same per-project patrol-scan budget and
alternates kinds across ticks; architecture occurrences are oldest-first.
Candidate selection takes one immutable, tick-scoped ownership snapshot so
registration/config/identity/continuation reads are shared across all due jobs
in that pass, including cached failures. Reservation never trusts that
snapshot: it resolves ownership live again, as do manual PR replay, action
resume, and every external-effect or handoff fence. Full
authority requires the target's exact registered name and expanded path to
still exist. Registration evidence is projected from that same normalized
name/expanded-path representation, so diagnostics and ownership keys cannot
drift. Hive resolves live origin host plus `owner/repo` for every enabled
registration and scans every registered project's action ledger, whether
currently enabled or disabled, for nonterminal remote continuation evidence.
A durable creation intent, PR URL, issue URL, or review-task path makes that
registration an owner of the action's source host/repository. Missing target
registration, duplicate enabled/continuation owners, or unreadable
config/identity/continuation state blocks visibly as
`repository_registration_missing`, `duplicate_repository_registration`, or
`repository_identity_unresolved`. The snapshot is never cached across
transitions.

`--actions` is the daemon resume primitive. `ActionRunner` reconstructs only
the immutable thesis snapshots stored in the job, resolves semantic families,
consults the global canonical-action proof archive/catalog, and processes fixes
before issues. Exact terminal proof from another registration is materialized
into the local aggregate as `canonical_action_link`, so the action becomes
terminal without rerunning a fixer, PR adapter, or issue adapter. Its v2
projection strips internal claims/timestamps while exposing action outcomes and
completeness in `action_status`.

Manual `--pr` uses this same manifest, policy snapshot, job claim, fencing
generation, checkpoint, and report path. The first invocation can intentionally
backfill a merge the catch-up baseline omitted. Invoking it again after that
job is terminal creates an explicit `-replay-N` occurrence with the current
policy snapshot and a freshly pinned current-default `analysis_sha`, while
preserving the original job bytes. Canonical action ids
still prevent duplicate remote effects across replays. Production ids hash the
normalized source host, repository, action kind, and either the fix fingerprint
or issue family id. Semantic-family descriptors and ids also include the source
host, so identical repository slugs on different GitHub/GHES hosts cannot share
an action or family identity.

## Read-only job inspection

`--list` and `--show JOB_ID` query the authoritative v2 `JobStore` in the CLI
process. They do not enqueue, claim, replay, resume, or otherwise mutate a job,
and they remain available for a registered project even when architecture
discovery is currently disabled. `--list` returns jobs in their immutable
durable intake sequence, with source identity, lifecycle state, counts, current
blockers, and update time. Pages default to 100 records (`--limit` accepts 1
through 100) and carry `has_more` plus an opaque `next_cursor`; pass that value
back through `--cursor` to continue. The first page fixes a sequence high-water
snapshot, so jobs arriving later, equal timestamps, and wall-clock rollback
cannot skip or enter that pagination run. `count` and `page.total` report that
snapshot's total while `page.returned` is the current page size.

The sequence projection lives under `v2/indexes/job-query/` as immutable
per-sequence sidecars plus an O(1) high-water record. Writer paths publish it
only after the authoritative job exists. A list query reads the high-water
once, opens at most `limit + 1` membership records, and parses only the selected
full jobs; it never scans every historical aggregate and never repairs or
writes the index. Missing, malformed, or mismatched membership fails closed.
`JobStore#rebuild_job_query_index!` is the explicit writer-side recovery path;
it changes the index generation so old cursors are rejected rather than
silently changing membership. The first authoritative write after upgrade also
migrates pre-index jobs. Newly created index ancestors are directory-fsynced
before `active.json` can expose the generation.

`--show` adds the stored source and policy snapshots, dispositions, feature
results, review errors, discovery attempts, and action records. Histories that
can grow across retries are bounded to their latest 100 entries by default:
discovery attempts, each action's claim history, and each action's publication
attempts. `job.history` reports total/returned/truncated counts for every slice.
For pre-attempt ledgers, flat `patch`, `patch_N`, and supersession receipts are
also bounded: normal show retains only the active legacy patch and reports the
full flat patch count as truncated, while `--full` returns the complete legacy
receipt history.

Use `--limit 1..100` to request a smaller history window or `--full` to
explicitly opt into the complete, potentially large history. `--full` and
`--limit` are mutually exclusive.

Text mode prints a compact operator summary. `--json` emits the versioned
`hive-refactor-patrol-jobs.v1` success/error contract. An unknown job id is a
`not_found` error with usage exit 64. Query options are mutually exclusive and
cannot be combined with `--pr`, `--job-manifest`, `--actions`, `--dry-run`,
legacy scope hints, or the internal result-file option. `--cursor` belongs only
to `--list`; `--full` belongs only to `--show`. Invalid job ids and query
modifiers—including `--limit`, `--cursor`, or `--full` without a selector—use
the jobs-v1 `usage` error arm with exit 64, while a valid but
missing id uses `not_found`; corruption in an existing valid-id record remains
a hard error and is never relabeled as missing.

Current action-block summaries use the per-action claim-generation snapshot
persisted with each new block. Only a strictly newer claim supersedes that
lifecycle blocker, independent of wall-clock rollback or same-second writes.
Legacy blocks without the snapshot use a conservative strictly-later timestamp
fallback, so ambiguous equality keeps the blocker visible.

## Fix and issue routing

Only accepted, unflagged theses from a job whose enqueue-time policy allowed
auto-fix can reach `Fixer`. The current config may revoke or narrow that
snapshot; it cannot raise caps, lower confidence/leverage thresholds, add a
validation command, switch agents, or otherwise broaden an old job.

Fixes run with the Codex workspace-write profile in a deterministic isolated
worktree on `hive-refactor/<canonical-action-id>`. The repository-global branch
keeps the same action on one branch across jobs, replays, and registration
handoffs. Hive fetches and validates the committed default-branch ref before
the fix and at publication fences; the operator's checked-out branch and dirty
files are irrelevant. Default-branch history must still descend from the
validated head. Before commit or push,
Hive checks actual feature-boundary paths, file/diff caps, protected paths,
secrets, dependency manifests, and public declarations across supported
ecosystems, then runs every named validation command. Unknown source languages
remain discoverable but fail automatic mutation when no public-contract guard
can prove safety. Documentation fixes need an explicit `docs` command; without
one, an admissible material thesis may file an issue but cannot open a PR.
When `refactor_patrol.commands.public_contract` is configured, it is an
authoritative executable guard and runs for every automatic fix that changes a
source or known public-surface path. Built-in declaration guards still enforce
their supported ecosystems; the project-owned command extends coverage rather
than weakening those checks. Ruby declaration checks scope `private`,
`protected`, and `public` state to each parsed class/module, preventing one
type's visibility from hiding a later type's public contract. Extensionless
scripts are recognized from either current or pinned-base shebang bytes and
remain report-only unless a configured public-contract command certifies them.
Disjoint trunk movement rebases only the isolated
patch and repeats the full audit; overlapping feature movement reruns the fix
from current clean trunk. Registered trunk is never reset, pulled, edited, or
committed by patrol.

`PrOpener` reconciles the complete same-branch PR set by exact action marker,
head SHA, base, repository, and GitHub host. Each validated patch generation
owns an append-only entry under `receipts.publication_attempts`, keyed by
`SHA256(publication_base_sha + NUL + commit_sha)` rather than by the ephemeral
action-claim generation. Its immutable descriptor names the exact patch receipt,
base SHA, and commit SHA. `push_intent`, `push_complete`, and
`pr_create_intent` are immutable append-only phases; PR-create intent requires
durable push completion, and a superseded or post-create attempt cannot advance.
`JobStore` is the only writer and applies the pure `PublicationAttempt` grammar
under the live action-claim fence before atomically committing each append.
Existing flat publication receipts are imported additively on first resume by
copying their exact matching phase payloads into the attempt. The original
legacy receipt entries are not rewritten; import only adds generation-scoped
copies and preserves their payload content byte-for-byte.

The exact action-generation fence still runs before durable intent and again
after intent immediately before a remote request. A rejected pre-intent fence
is known-not-sent. On restart Hive first reconciles the exact remote branch: a
landed push whose completion receipt was interrupted gets durable
`push_complete` evidence before drift can supersede it. Hive then checks that
registered trunk still equals the attempt's publication base before push work,
and checks it again after proving the exact remote head immediately before
`pr_create_intent`. Drift appends an immutable `superseded` record with the
observed trunk SHA; the fixer then produces a new patch/base pair and therefore
a new attempt id. Once
`pr_create_intent` is durable, supersession is forbidden and an ambiguous result
or changed remote head remains reconciliation-only.

Publication requires exactly one origin push URL and reuses it for remote-OID
lookup and push, so a later `origin` rewrite cannot redirect the transaction.
New branches use an exact absence lease. A replacement is authorized only when
the remote OID equals the commit of an older attempt that has both durable
`push_complete` proof and durable supersession; the push then uses that exact
old OID as its force-with-lease expectation. An arbitrary pre-existing remote
branch remains a conflict. Publication phases themselves are remote
continuation evidence, so disabled registrations still participate in unique
repository ownership. Continuation-only claims may reconcile an existing
request (or record completion of an already-intended push), but cannot create a
replacement patch or begin a new push/PR phase.

After `gh pr create`, an
exact-host/repository `gh pr view` must prove the returned URL/number, OPEN
non-draft state, head repository/branch/OID, and the exact base branch/OID from
the validated patch before handoff.
Same-branch reconciliation also rejects an OPEN PR unless `isDraft` is
explicitly false; CLOSED/MERGED recovery remains available when draft metadata
is absent because those states cannot be handed off as a live ready PR.
Failure becomes reconciliation-only `remote_outcome_unknown`. Both new and
reconciled PRs recheck continuation ownership and the live action claim
immediately before enqueueing `6-review`. An OPEN or MERGED publication is
successful only after that mandatory handoff; an externally CLOSED-unmerged PR
terminates as `closed_without_merge`. Patrol never merges the PR itself.

Issue filing is limited to admissible strategic/cap-blocked theses or accepted
theses that become deterministically non-fixable, and also requires material
proposal-specific leverage. Semantic families deduplicate reworded occurrences
across jobs. A successful fix in any thesis of a family suppresses the family
issue. Family JSON is a rebuildable projection from authoritative job
aggregates, not independent completion state.

Reconciliation reads the complete paginated open-and-closed issue inventory
for the exact host/repository. It checks the current v2 marker first. Only when
no exact marker exists does it parse markerless historical
`refactor-patrol:` bodies, requiring one feature identity, thesis and
fingerprint identity, all problem/cost/refactor/evidence sections, and
file-and-line evidence before deriving a semantic descriptor. Every candidate
must be pairwise family-compatible or reconciliation fails closed. Receipts
record `match_kind: v2_marker` or `legacy_semantic`, keeping compatibility
visible without letting loose title similarity suppress a new issue.

Both issue and PR publication derive the target host and `owner/repo` from the
source PR, including GitHub Enterprise. Bodies are bounded and secret-scanned.
Creation intent is durable and exact; after an ambiguous result, automated
recovery reconciles open/closed remote objects and never submits a second
create request.

If the registered repository identity later changes, only the individual
actions already carrying remote intent/URL/handoff evidence may reconcile that
existing effect. Unstarted siblings remain queued and the job records
`repository_identity_drift`; a continuation claim cannot pass a new push/create
fence. Duplicate or unresolved global ownership blocks even reconciliation
until one owner remains and every registered config/continuation scan plus each
participating live identity is resolvable. If the default branch advances after
partial discovery pins its analysis SHA, the job preserves completed slices,
reuses the original SHA, and rematerializes the same detached exact worktree
for only the incomplete slices. Hive never mixes snapshots or resets trunk.

## State and JSON

Legacy state remains under `.hive-state/refactor_patrol/`. It shares directory,
atomic JSON-write, tolerant-read, and run-artifact mechanics with ordinary
patrol through `Hive::Patrol::BaseStateStore`, while retaining its own namespace
and thesis schema. V2 uses a separate namespace:

```text
.hive-state/refactor_patrol/v2/
  reconciler.json               # exact-host catch-up checkpoint, schema v2
  reconciler-progress.json      # identity-bound page/intake cursor, schema v1
  manifests/<job-id>.json       # write-once source occurrence
  jobs/<job-id>.json            # authoritative aggregate + claims/receipts
  families/<family-id>.json     # rebuildable semantic-family projection
  indexes/                      # rebuildable fingerprint/action indexes
  results/<dispatch-id>.json    # daemon completion channel; removed on reap
  runs/ and logs/               # agent evidence
```

Terminal remote-effect proof is repository-global rather than registration
local:

```text
<Hive::Paths.state_home>/refactor_patrol/v2/
  terminal-proofs/<canonical-action-id>.json # immutable terminal proof
  indexes/canonical-actions.json             # disposable/rebuildable catalog
  canonical-actions.lock
```

An archive entry is first derived from a validated terminal owner aggregate (or
an exact already-materialized proof link), then never rewritten. The catalog is
only a locator projection and may be deleted or rebuilt. Immutable archives
preserve exact PR/issue/handoff proof across catalog corruption, project
deregistration, or removal of the original project path; an unreadable or
conflicting archive blocks action instead of reopening the remote effect.
Mandatory review-handoff paths remain valid after their synthetic coding task
advances from `6-review` through `7-artifacts`, `8-finalize`, or `9-done`, so a
later catalog rebuild can recover terminal PR proof instead of mistaking stage
movement for a missing handoff. Paths outside those exact stage roots, or nested
below a task folder, still fail closed.

Legacy no-PR JSON remains `hive-refactor-patrol.v1`; its success payload now
includes `review_complete`, `review_errors`, and per-feature progress so a
token-limited or failed review cannot look like a clean zero-thesis result.
Structured cap evidence is retained under
`review_errors[].details.resource_exhaustion`. PR discovery and action
resume emit `hive-refactor-patrol.v2`, including source identity,
`analysis_sha`, completeness, per-feature progress,
accepted/flagged/suppressed dispositions, review errors, attempts, and public
action receipts. V2 thesis snapshots carry
the complete normalized thesis rather than only identity fields.
Pre-dispatch `--json` usage errors follow the same mode: legacy argv receives a
schema-valid v1 error, while `--pr`, `--job-manifest`, or enabled `--actions`
argv receives a schema-valid v2 error with the required empty job/source and
`complete: false` projection.

Read-only `--list` and `--show` use a separate
`hive-refactor-patrol-jobs.v1` schema. List responses contain validated job
summaries plus bounded, sequence-snapshot continuation metadata; show responses contain one
validated durable detail projection with bounded-history metadata or an
explicit `full: true` projection.
Their query-specific error arm preserves the requested `action` (`list` or
`show`, or null for a selector-less query modifier) without falling through to
either discovery reporter.

Daemon children write their v2 document atomically to the job-bound internal
result file. Stdout remains operator logging, so a valid snapshot larger than
the supervisor's ordinary 64 KiB log tail is not truncated into a false retry.

`--dry-run` applies the same current-policy, exact-registration, ownership, and
discovery-consent checks read-only, then previews discovery, would-initialize
actions, or resumptions. An uninitialized action job whose discovery consent
was revoked reports `discovery_revoked` with `would_complete: false`; it does
not invent report-only completion. Dry run never writes manifests, ledgers,
indexes, global catalogs or proof archives, durable worktrees, branches,
commits, PRs, issues, handoffs, or completion checkpoints. PR-scoped discovery
may materialize the same temporary detached analysis tree as a real run, but
removes it before returning; authoritative job bytes remain unchanged.

## Backlinks

- [[commands/patrol]]
- [[commands/init]]
- [[modules/config]]
- [[modules/daemon]]
- [[modules/gh]]
- [[state-model]]
- [[testing]]
