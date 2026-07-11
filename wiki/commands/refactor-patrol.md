---
title: hive refactor-patrol
type: command
source: lib/hive/commands/refactor_patrol.rb, lib/hive/refactor_patrol/*
created: 2026-07-02
updated: 2026-07-11
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
```

Fresh terminal and web init recommend discovery (`refactor_patrol.enabled:
true`) with a default-yes choice. Missing configuration in an existing project
still resolves to false. The two external-effect gates never inherit discovery
consent and default off:

```yaml
refactor_patrol:
  enabled: true
  # Proposal-specific leverage below this floor remains visible but report-only.
  min_leverage_score: 0.25
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
manifest, and pin a clean attached default-branch `analysis_sha` that contains
the merge. The daemon consumes only the write-once manifest published by merge
intake; it never re-fetches mutable PR metadata during discovery.

Discovery uses provider-specific read-only enforcement and snapshots the
registered checkout before and after review. Every thesis appears exactly once
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

Documentation mapping is a refactor-patrol-only capability. When appropriate,
it maps bounded root-document, `docs/`, wiki, ADR, and decision slices. Compiled
wiki logs, raw notes, caches, generated content, and `.hive-state` do not become
one broad documentation feature. Ordinary `hive patrol` mapping is unchanged.

`max_theses_per_run` is a strict run-wide reviewer budget, not a per-feature
allowance: once exhausted, later slices stay incomplete for a future resume.
Malformed envelopes, null/scalar items, and schema-invalid records are review
errors rather than successful zero-result scans. Evidence is also checked
against the pinned checkout's real, root-confined bytes: cited files must
exist, line anchors must be in range, and snippets must occur exactly when
present. One unverified citation makes the thesis inadmissible. Proposal
leverage is derived from measured hotspot signals and model-explained relief;
the default `min_leverage_score: 0.25` keeps low-value extraction proposals
visible but prevents automatic action. If architecture mapping fails, leverage
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

The v2 job lifecycle is `queued → analyzing → classified → acting → complete`.
Discovery and actions use generation-fenced claims renewed by exact
PID/process-start heartbeats; workers without verifiable process identity do
not claim work. `PatrolArbiter` gives
ordinary and architecture scans the same per-project patrol-scan budget and
alternates kinds across ticks; architecture occurrences are oldest-first.
Every scheduler selection/reservation, manual PR replay, action resume, and
external-effect or handoff fence takes a fresh ownership snapshot. Full
authority requires the target's exact registered name and expanded path to
still exist. Hive resolves live origin host plus `owner/repo` for every enabled
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
policy snapshot while preserving the original job bytes. Canonical action ids
still prevent duplicate remote effects across replays. Production ids hash the
normalized source host, repository, action kind, and either the fix fingerprint
or issue family id. Semantic-family descriptors and ids also include the source
host, so identical repository slugs on different GitHub/GHES hosts cannot share
an action or family identity.

## Fix and issue routing

Only accepted, unflagged theses from a job whose enqueue-time policy allowed
auto-fix can reach `Fixer`. The current config may revoke or narrow that
snapshot; it cannot raise caps, lower confidence/leverage thresholds, add a
validation command, switch agents, or otherwise broaden an old job.

Fixes run with the Codex workspace-write profile in a deterministic isolated
worktree on `hive-refactor/<canonical-action-id>`. The repository-global branch
keeps the same action on one branch across jobs, replays, and registration
handoffs. The registered checkout must stay clean, attached to the configured
default branch, and descendant of its validated head. Before commit or push,
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
head SHA, base, repository, and GitHub host. It records distinct push intent,
push-completion, and PR-create intent phases, with the exact action-generation
fence before durable intent and again after intent immediately before the
request. A rejected pre-intent fence is known-not-sent; once PR-create intent
is durable, an ambiguous result or changed remote head becomes
reconciliation-only. It requires exactly one origin push URL, captures that
validated URL once, and uses it for both remote-OID
lookup and push so a later `origin` rewrite cannot redirect publication. New
branches use an exact absence lease; replacements use an exact expected-OID
lease tied to a proven prior patch generation. An arbitrary pre-existing remote
branch is a conflict, never a force-push target. After `gh pr create`, an
exact-host/repository `gh pr view` must prove the returned URL/number, OPEN
non-draft state, head repository/branch/OID, and base branch before handoff.
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
participating live identity is resolvable. If registered default-branch HEAD
moves after partial discovery has pinned its analysis SHA, the job preserves
completed slices and blocks visibly as
`analysis_checkout_changed_after_pin` with expected/current SHAs. Hive does not
mix snapshots, reset trunk, or create an implicit analysis worktree.

## State and JSON

Legacy state remains under `.hive-state/refactor_patrol/`. V2 uses a separate
namespace:

```text
.hive-state/refactor_patrol/v2/
  reconciler.json               # exact-host catch-up checkpoint, schema v2
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

Legacy no-PR JSON remains `hive-refactor-patrol.v1`. PR discovery and action
resume emit `hive-refactor-patrol.v2`, including source identity,
`analysis_sha`, completeness, per-feature progress,
accepted/flagged/suppressed dispositions, review errors, attempts, and public
action receipts. V2 thesis snapshots carry
the complete normalized thesis rather than only identity fields.

Daemon children write their v2 document atomically to the job-bound internal
result file. Stdout remains operator logging, so a valid snapshot larger than
the supervisor's ordinary 64 KiB log tail is not truncated into a false retry.

`--dry-run` applies the same current-policy, exact-registration, ownership, and
discovery-consent checks read-only, then previews discovery, would-initialize
actions, or resumptions. An uninitialized action job whose discovery consent
was revoked reports `discovery_revoked` with `would_complete: false`; it does
not invent report-only completion. Dry run never writes manifests, ledgers,
indexes, global catalogs or proof archives, worktrees, branches, commits, PRs,
issues, handoffs, or completion checkpoints, and authoritative job bytes remain
unchanged.

## Backlinks

- [[commands/patrol]]
- [[commands/init]]
- [[modules/config]]
- [[modules/daemon]]
- [[modules/gh]]
- [[state-model]]
- [[testing]]
