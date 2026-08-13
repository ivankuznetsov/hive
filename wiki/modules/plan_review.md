---
title: Plan review
type: module
source: lib/hive/plan_review.rb, lib/hive/plan_review/, lib/hive/commands/plan_review.rb, schemas/hive-plan-review.v1.json
created: 2026-08-12
updated: 2026-08-13
tags: [plan, review, policy, findings, coverage, execution, audit]
---

**TLDR**: Every built-in coding task now has a policy-driven critique substate
inside `3-plan`. A readable `plan.md` is classified as `skip`, `standard`, or
`mandatory`; non-skipped plans receive whole-document and independent
adversarial review, typed findings, at most one original-planner revision, and
one verification pass. Only the freshness-bound `plan-review/current.json`
resolution can authorize `3-plan` to `4-execute`. Markers, generic approval,
`--force`, daemon automation, Web forms, and direct execute entry cannot replace
that authority.

## Applicability and boundary

The first release applies only when all of these are true:

- the workflow is the built-in `coding` workflow;
- the task remains in `3-plan` when critique is initialized; and
- `plan.md` is a regular, readable UTF-8 file inside the task folder.

There is no tenth workflow stage and no descriptor extension. Custom workflows,
architecture/research/content/bench flows, and coding tasks already beyond plan
project `plan_review: null`. New coding tasks carry
`meta.yml: plan_review_required: true`; `hive migrate` adds that bit to existing
coding tasks in stages 1–3 while leaving stages 4+ grandfathered. Consequently,
an already-executing pre-feature task with no review root receives a private
`legacy-execute-adoption.json` receipt, while removing evidence and raw-moving a
new/migrated task fails closed at execute entry.

## Deterministic policy

`Hive::PlanReview::PlanSignals` reads declared files, explicit test scenarios,
rollback/reversibility text, file count/locality, protected-path matches, and
bounded risk text. It never executes project code and rejects symlinks,
traversal, invalid UTF-8, oversized input, and malformed evidence.
Declared-file and test evidence may use repeated Markdown headings or repeated
bold labels such as `**Files:**` and `**Test scenarios:**`. Oversized YAML
frontmatter remains explicit uncertainty rather than disappearing, and a
recognized literal credential pattern always selects mandatory review even
when nearby prose never says "secret" or "credential".

| Level | Rule | Availability behavior |
|---|---|---|
| `skip` | Every affirmative low-risk predicate is present: bounded declared files in one local component, an explicit test path/scenario, explicit rollback, and no mandatory signal. | Writes policy and resolution evidence; invokes no reviewer. |
| `standard` | Default for ordinary, incomplete, or uncertain evidence. | Retries transient failures within the configured bound. Core success plus optional loss becomes `degraded_cleared(partial_coverage)`; bounded core unavailability becomes `degraded_cleared(review_unavailable|terminal_failure)`. |
| `mandatory` | Authentication/secrets/permissions, destructive data/schema work, public compatibility, concurrency/recovery/ownership, deployment/release/supply-chain, or a configured protected path. | Missing, failed, unsupported, timed-out, or non-independent required coverage blocks until an exact operator waiver or mandatory downgrade is recorded. |

Project and coding-workflow minimums plus `hive plan --review-level standard|mandatory`
are raise-only. A lower mandatory level can come only from a current audited
`downgrade-level` decision. The policy fingerprint covers classifier version,
normalized policy settings, extracted evidence, and every level source.

## Reviewer and routing contract

`Hive::PlanReview::Adapters::Base` owns a provider-neutral request/result
contract. `CeDocReview` passes a redacted immutable snapshot into a disposable
directory and invokes the configured `ce-doc-review` capability for the primary
whole-document/specialist leg. The adversarial leg uses a separate prompt and
route. Neither reviewer can publish canonical `plan.md`; malformed or free-form
output has no clearance authority.

Reviewer and original-planner revision launches are confined to disposable
workspaces with provider-enforced workspace-write or exact Claude file-tool
scope. A provider that cannot enforce either boundary is unavailable rather
than inheriting a bypass-permissions default. The reviewed input is itself a
protected anchor, so findings cannot be minted against a reviewer-mutated copy.

The default adversarial request is native Grok Build, model `grok-4.6`, effort
`high`. Every route records requested and actual provider, model, model family,
effort, native launcher, capability result, outcome, attempt, retry time, and
independence result. Route receipts retain the preferred request plus every
probe attempt even when a later fallback is selected. Resolution continues
past present same-family or unknown-family candidates in search of a configured
attested different-family fallback. A fallback satisfies adversarial coverage only when both
families are known and the actual reviewer family differs from the captured
planner family. Same-family or unknown-family output remains evidence but its
adversarial coverage row is forced to `failed`.

Adapter outcomes are closed: `success`, `partial_coverage`, `unsupported`,
`provider_limit`, `timeout`, `retryable_failure`, and `terminal_failure`.
`unsupported` is stable and consumes no transient retry. Provider limits,
timeouts, and retryable failures preserve retry metadata and use at most one
initial attempt plus `plan_review.attempts.max_transient` retries for primary,
adversarial, verification, and original-planner revision legs. Provider-route
exceptions are normalized into those durable attempt outcomes rather than
escaping before retry evidence is written. Missing retry hints receive bounded
exponential delay with deterministic jitter rather than a hot retry loop.

## Findings, revision, and verification

Findings have stable semantic fingerprints, anchored evidence, risk, and one
of four classes:

- `safe_auto`: accepted automatically, but only the original planner may
  incorporate it;
- `gated_auto`: requires an exact operator approval or an exact current scoped
  approval-policy receipt;
- `manual`: requires an answer, then planner incorporation and verification;
- `fyi`: retained as non-blocking evidence.

The fingerprint binds classification, risk, source, and exact plan evidence,
but deliberately excludes model-authored title, description, and excerpt
prose. The adapter verifies each `plan.md` line range and its normalized
line-range SHA-256 against the immutable reviewed snapshot before the finding
can affect revision or approval policy.

Accepted findings are batched into one `PlannerRevision` call using the
captured planner provider/model/family/effort. That call writes only
`candidate-plan.md`. Hive then runs one bounded disposition/regression
verification leg. Each accepted finding requires explicit fingerprint-bound
verification evidence; absence from a generic critique does not verify it. A
remaining or newly discovered blocker stops the lineage; it
cannot trigger a recursive second revision. In particular, `request-review`
cannot clear a verification-created finding without a new linked plan
generation and planner incorporation. A verified candidate is atomically
promoted to canonical `plan.md` under the task mutation lock immediately before
its matching terminal resolution is published under that same lock.

## Durable identity and artifacts

Each task owns an owner-private `plan-review/` tree:

```text
plan-review/
  current.json
  level.json                         # present only after a run-level raise
  reviews/<review-id>/
    manifest.json
    policy-<policy-fingerprint>.json
    attempts/<attempt-id>/
      input-plan.md
      result.json
      coverage.json
      route-receipt.json
    decisions/<target>/<decision-id>.json
    candidate-plan.md                # only when revision was required
    resolution-v<projection-version>.json
```

Attempt, decision, policy, candidate, and resolution artifacts are immutable,
content-addressed from `current.json`, redacted before publication, and checked
for regular-file type, confinement, byte size, and SHA-256 digest on every
authority-bearing read. Current projection publication is version-CAS under a
task-local lock. A late result is retained but cannot replace a newer pointer.
Deterministic manifest and terminal-resolution publication is crash-recoverable:
a retry reuses an identical orphaned immutable artifact instead of conflicting
on a fresh timestamp before `current.json` can advance.

The logical review ID binds task identity, initial plan generation/digest,
policy fingerprint, and prior lineage identity. Transient retries stay in that
lineage and preserve stable finding decisions. An external plan edit or
material policy change creates a new review whose `prior_review_id` points at
the previous manifest; returning A-to-B-to-A creates a third linked review
instead of colliding with immutable history.

## Terminal resolution and transition authority

| State/outcome | Execution | Meaning |
|---|---:|---|
| `skipped` | yes | Durable low-risk classification; zero reviewer calls. |
| `cleared` | yes | Requested coverage, decisions, revision (if any), and verification cleared. |
| `degraded_cleared` | yes | Standard-only explicit partial/unavailable/terminal-failure exception. |
| `blocked` | no | Mandatory coverage, verification, planner, or evidence requirement remains unmet. |

`TransitionGuard.prepare!` may run/resume critique before a forward mutation.
`TransitionGuard.verify!` re-reads the exact review/version/observation digest,
task generation, canonical plan digest, policy configuration, and run-level
receipt under the task lock immediately before movement. `StageAction`,
`Approve`, daemon plan approval, and execute entry all use this guard. A stale,
missing, corrupt, blocked, or changed observation raises a typed
`PlanReview::TransitionBlocked`; `--force` does not bypass it.

## Automation and operator actions

`hive plan-review-run TARGET` is the non-authority automation entrypoint used by
status and the daemon. It may initialize review, dispatch/retry reviewers,
perform an already-authorized revision, verify, and advance an already-cleared
plan. It has no API for approvals, answers, waivers, or downgrades.

Authority-bearing actions use:

```text
hive plan-review TARGET ACTION \
  --review-id REVIEW_ID \
  --task-generation GENERATION \
  --policy-fingerprint SHA256 \
  --expected-artifact-digest SHA256 \
  [--target-fingerprint FINGERPRINT] [--answer TEXT] \
  [--coverage NAME] [--level LEVEL] [--reason TEXT]
```

Actions are `approve-finding`, `answer-finding`, `waive-coverage`,
`downgrade-level`, `raise-level`, `retry`, and `request-review`. Every action is
observation-bound and idempotent: an identical replay is a no-op, a stale
observation exits temporary-failure, and a conflicting target decision is
rejected. Both CLI and Web recheck the canonical plan, task generation, policy
configuration, and run-level receipt inside the mutation lock before writing a
decision. Waivers and downgrades require a human-readable reason. The JSON
result is `hive-plan-review-action.v1`.

Under ADR-008's local same-user trust model, direct CLI invocation is the
operator boundary; Web actions use the authenticated access predicate. An
agent with unrestricted same-user shell access therefore has CLI authority.

Project-local approval policies can consume a gated finding only when policy
ID/version, validity/revocation, action, risk, paths/scope, review ID, and policy
fingerprint match exactly. Consumption leaves a durable policy receipt.

## Shared status and Web projection

`hive-status.v7` and `hive-operational-status.v4` contain one required nullable
`plan_review` field. Applicable rows include review and observation identity,
computed/effective level, state/outcome, degradation reason, attempt/current
attempt, coverage and finding counts, blockers/owner/reason, retry time, one
required action, sanitized route receipts, artifact references, freshness, and
`execution_allowed`. Daemon rows and `Hive::Tui::Snapshot::Row` copy that
object; they do not derive a second policy result.

Hive Web renders the same object on task detail, opens only current
content-addressed safe artifacts, and posts the full observation identity to
the shared `DecisionService`. Stale or conflicting posts refresh the current
review without mutation. Its Run action dispatches the projected
`plan_reviewing` or due `plan_review_retry` command as `plan-review-run`, and a
mandatory failed or unsupported coverage row exposes an exact waiver form even
when that row began as configured optional coverage. While a plan review
applies, the generic force-approve control is hidden.

## Tests and proof

- `test/unit/plan_review/` covers policy, identity, immutable storage, parser,
  adapter, routing, coverage, decisions, orchestration, and transition safety.
- `test/integration/plan_review_action_test.rb` and
  `test/integration/plan_review_lifecycle_test.rb` cover public decisions,
  denial/clearance, lineage rollover, legacy adoption, and terminal proof.
- `test/fixtures/plan_review/terminal_outcomes.json` is the deterministic
  cross-surface proof snapshot for `skipped`, `cleared`, standard
  `degraded_cleared`, and mandatory `blocked`.
- `test/smoke/plan_review_smoke_test.rb` is the explicitly opt-in authenticated
  native Grok `grok-4.6` route/independence proof. It skips with a diagnostic
  when opt-in, binary, or authentication is unavailable.

## Backlinks

- [[stages/plan]] · [[stages/execute]]
- [[modules/config]] · [[modules/daemon]] · [[modules/model_routing]] · [[modules/task_action]]
- [[commands/status]] · [[commands/daemon]] · [[commands/web]] · [[cli]]
- [[decisions]] · [[testing]] · [[gaps]]
