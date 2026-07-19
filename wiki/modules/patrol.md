---
title: Hive::Patrol
type: module
source: lib/hive/patrol/
created: 2026-05-28
updated: 2026-07-19
tags: [module, patrol, review, worktree, pr, codex]
---

**TLDR**: `Hive::Patrol::*` is the ordinary repository-patrol engine behind [[commands/patrol]]. It keeps clawpatch-style work units and audit state as plain JSON under `.hive-state/patrol/`, delegates review/fix reasoning to configured Hive agent profiles, records patrol review/fix token usage in `Hive::UsageDb`, validates fixes in isolated worktrees, opens PRs, and by default hands opened PRs into the normal `6-review` flow through `Hive::Patrol::ReviewHandoff`. The separately configured, post-merge architecture patrol lives under `Hive::RefactorPatrol::*`; the two schedulers share project/day ceilings while architecture gets a larger cycle allowance, and they do not share state, mapping, policy, or action ledgers.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Patrol::Mapper` | `lib/hive/patrol/mapper.rb` | Ordinary patrol enables the shared architecture capability: non-overlapping language-neutral source/manifest components with dependency-ranked context and subsystem tests, plus one primary review per command or grouped manifest-script contract. Command paths remain component context, not duplicate evidence anchors. Legacy route/package/monolithic-test slices remain available only to callers that omit that capability. |
| `Hive::Patrol::SourceReader` | `lib/hive/patrol/source_reader.rb` | Shared root-confined, regular-file-only, 256 KiB bounded reader used by architecture mapping and leverage measurement. It resolves tracked symlinks beneath the canonical project root and skips external/device targets before reading. |
| `Hive::Patrol::Feature` | `lib/hive/patrol/feature.rb` | Durable feature record: `id`, `kind`, `entrypoints`, `owned_files`, `context_files`, and `tests`. |
| `Hive::Patrol::FeatureBatch` | `lib/hive/patrol/feature_batch.rb` | Selects the deterministic SHA-bound rotating component batch and returns the next persistent cursor. `Commands::Patrol` strictly fetches the explicit remote head for each new sweep, fails closed rather than scanning stale local main when that fetch fails, and records an explicit active snapshot so an in-progress sweep can finish its pinned SHA even when default advances or the first batch errors at cursor zero. If that commit becomes unmaterializable, the command starts from the current default and `FeatureBatch` resets the cursor. |
| `Hive::Patrol::Reviewer` | `lib/hive/patrol/reviewer.rb` | Requests zero-to-three evidence-backed production defects per feature; bounded output must match the exact JSON envelope and is accepted atomically only when every admitted item has complete contract/impact/root-cause/scope/reproduction/validation fields and its confined evidence line contains the supplied snippet. Finding ids include the unique review-run id so audit records are immutable. |
| `Hive::Patrol::Finding` | `lib/hive/patrol/finding.rb` | Durable finding record with delivery metadata (`scope`, contract, impact, root cause, reproduction, validation, computed alpha score) while retaining backward-compatible v1 loading. |
| `Hive::Patrol::Fingerprint` | `lib/hive/patrol/fingerprint.rb` | Structured findings use a feature-independent semantic SHA over category, primary evidence path, contract, and root cause. Historical v1 findings retain the legacy identity fallback. Stored title/root-cause tokens provide cross-wording similarity, while feature metadata supports outcome calibration. |
| `Hive::Patrol::CandidateSelector` | `lib/hive/patrol/candidate_selector.rb` | Applies production/history/active-feature hard gates, computes deterministic 0–100 alpha from validated proof fields, clusters semantic duplicates even within one feature, maps legacy slice IDs narrowly to current components, enforces per-feature diversity, and returns a globally ranked portfolio. Successful merged history is not treated as negative alpha. |
| `Hive::Patrol::Fixer` | `lib/hive/patrol/fixer.rb` | Strictly fetches an exact base, applies the changed-path guardrail, and accepts bounded agent-reported audit/regression paths without language conventions. The proof reader opens agent output with no-follow/nonblocking flags, rejects non-regular files, and caps bytes before JSON parsing. Hive overlays the declared changed regressions onto an isolated base, requires a normal regression-identified failure and patched pass, then broader validation. An errored **or timed-out** fix agent run (`Agent#run!` status `:error`/`:timeout`) fails closed as `fix_agent_failed` — its half-finished changes are never validated or shipped. Agent rejection is an attempt outcome, not durable resolution; reconciliation and failed handoff states reuse the exact validated patch. |
| `Hive::Patrol::Validator` | `lib/hive/patrol/validator.rb` | Identifies and runs operator-configured validation commands in the fix worktree. A normal patrol command rejects an empty command set before state mutation or agent work; direct fixer callers still fail closed. |
| `Hive::Patrol::PrOpener` | `lib/hive/patrol/pr_opener.rb` | Fail-closed secret-scans the title, body, and exact validated diff; verifies a clean exact local head, remote base, leased push, remote head, and created/existing PR identity; records fingerprint-to-PR state; and invokes `ReviewHandoff`. After `gh pr create`, `reconciliation_pending` stores the exact URL and patch/base/head/worktree receipt while retaining the validated worktree. New and retried handoffs require the hosted base OID and perform a final live remote base/head check immediately before task publication. Retries reconcile only the receipted URL/base/head and mark the ledger `open` only after review handoff settles, so lookup lag cannot orphan a PR or suppress/rerun the finding. Dynamic publication diagnostics are separate from closed reason codes. |
| `Hive::Patrol::ReviewHandoff` | `lib/hive/patrol/review_handoff.rb` | Creates a synthetic `6-review/patrol-.../` task for an opened patrol PR when `patrol.review_prs` is not false, preserving the patrol worktree and observed proof so the standard review daemon can run reviewers/triage/fix/browser flow. Mandatory and optional calls use the same fingerprint-locked exact reconciliation, so a retry after rename/fsync ambiguity reuses the matching task and rejects PR/head identity conflicts. Staging/quarantine renames use the shared best-effort directory-fsync policy. |
| `Hive::Patrol::AgentLaunch` | `lib/hive/patrol/agent_launch.rb` | Builds the provider-specific patrol launch envelope. Claude reserves 20,000 tokens for provider-owned initial context plus one conservative token per prompt byte, uses a verified minimal review/fix tool set, and caps reviews at three completed turns. |
| `Hive::Patrol::ReviewErrorDetails` | `lib/hive/patrol/review_error_details.rb` | Converts an agent resource-exhaustion result into the shared durable review-error detail envelope used by ordinary and architecture patrol. |
| `Hive::Patrol::TokenBudget` | `lib/hive/patrol/token_budget.rb` | Shares measured-token and agent-launch ceilings across ordinary review/fix and architecture discovery/action phases and supplies an actual per-launch streamed-token cap to `Hive::Agent`. A launch is refused before spawn when the remaining per-agent/cycle/day allowance cannot cover `AgentLaunch`'s initial reserve. A project-keyed advisory lock serializes full agent lifetimes so daily headroom cannot be double-spent by concurrent workers. Architecture defaults to a 2x cycle/per-agent-token envelope, while the native budget guard and durable current-day project ceiling remain shared. Missing usage is recorded as an unmetered launch. |
| `Hive::Patrol::Dismissals` | `lib/hive/patrol/dismissals.rb` | Reconciles closed-unmerged patrol PRs into `dismissed.json` so the same finding is not immediately re-filed. Retryable publication entries match only their exact receipted PR URL and remain retryable while that PR is open. |
| `Hive::Patrol::BaseStateStore` | `lib/hive/patrol/base_state_store.rb` | Shared JSON lifecycle for ordinary patrol and architecture patrol's legacy reporting state: directory creation, state/fingerprint/dismissal files, run artifacts, and tolerant reads. It delegates atomic replacement to `Hive::AtomicFile` while preserving the stores' prior no-fsync behavior. |
| `Hive::Patrol::StateStore` | `lib/hive/patrol/state_store.rb` | Defines the ordinary-patrol collections and records written under `.hive-state/patrol/`; architecture patrol retains its own subclass, namespace, and thesis records. |

## State

Patrol state is deliberately inspectable and removable:

```text
.hive-state/patrol/
  features/*.json
  findings/*.json
  patches/*.json
  runs/*/                         # agent transcripts/output
  runs/selection-*.json           # immutable score/decision audit
  state.json
  fingerprints.json
  dismissed.json
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
pinned SHA even after the default branch advances.

The two reviewers now use deliberately different breadth. Ordinary mapping
defaults to four owned plus four context files. Architecture keeps six plus six
for deterministic hotspot/leverage measurement, but presents at most four
owned files selected with a 32 KiB source budget in the initial agent view; an
oversized first entrypoint is retained. Both prompts permit
only one evidence-driven follow-up round and explicitly prefer an empty result
to speculation. A Claude review receives only `Read`, `Grep`, `Glob`, and
`Write`, with slash commands disabled; a fix additionally receives `Bash` and
`Edit`. The third completed review turn is terminal after an already-generated
`Write` and its final usage delta settle in either provider event order. When a
non-empty output artifact has been written, Hive terminates the child and lets
the existing schema/evidence parser decide whether the result is admissible.

The two systems share only the legacy JSON persistence mechanics in
`Hive::Patrol::BaseStateStore`; their domain records and proof remain separate.
They deliberately retain separate namespaces:
`.hive-state/patrol/` for ordinary patrol and
`.hive-state/refactor_patrol/v2/` for architecture manifests, jobs, semantic
families, indexes, and result receipts. `Hive::Daemon::PatrolArbiter` is the
only shared orchestration seam: it alternates ready work under the project's
`daemon.max_concurrent_patrol_scans` capacity. Enabling architecture discovery
does not enable ordinary patrol, auto-fixing, or issue filing, and neither
system can consume the other's state as proof of completion.

## Daemon triggers

Patrol is **opt-in**. A project with **no patrol section at all** (or a patrol section that omits `mode:`) resolves to `enabled: false` — [[modules/config]] only derives mode knobs when `mode:` is **explicitly present** in the raw config. `medium` is the default offered by the `hive init` *prompt* (which writes an explicit `mode: "medium"` into the rendered template), never a config-resolution default, so legacy projects without a patrol block are never silently enabled.

Operators normally configure scheduling through `patrol.mode`, which [[modules/config]] resolves into cadence plus token, launch, native budget-equivalent, and per-launch token ceilings before the daemon sees the project config. `ultrapatrol`, `high`, `medium`, and `low` deliberately receive progressively smaller envelopes as cadence falls; `off` resolves to `enabled: false`. Measured input, output, and cached tokens from both ordinary and architecture stages share the same project/day total. Architecture stages apply `architecture_budget_multiplier` (default `2`) to cycle token/launch limits and the streamed per-agent token cap, not the native budget-equivalent guard. Unmetered children still consume launch quota, so a provider that cannot report token totals cannot bypass the tier. Explicit granular knobs always win over a set mode and survive the deep-merge even when no `mode:` is set.

Each patrol launch also needs enough remaining allowance for its profile's
provider-owned initial context reserve plus the rendered prompt bytes. If not,
`TokenBudget#acquire` returns `insufficient_launch_headroom` without spawning
or consuming another subscription-backed request. It returns the more specific
`daily_token_headroom` when the shared UTC-day remainder is the binding limit,
allowing architecture patrol scheduling to sleep until the next UTC window.
This admission check covers
ordinary and architecture review/fix launches; architecture's 2x multiplier
still cannot bypass the shared daily project cap.

Ordinary review batching also accounts for that shared launch envelope before
agents start. It selects no more features than the tighter remaining cycle or
UTC-day quota can launch and, except when at most one launch remains or during a
dry run, leaves one launch for a fixer. When a later review fails, the SHA-bound
cursor advances past only the proven-clean prefix; the failed feature and
remaining suffix stay pinned for retry.

`Hive::Daemon::PatrolScheduler` still consumes the lower-level `patrol.trigger` modes. `continuous` dispatches when either the default branch SHA changed or `poll_interval_sec` has elapsed, allowing patrol to keep reviewing existing feature slices between infrequent merges. Each cycle persists a SHA-bound feature cursor; `last_scanned_sha` advances only after the full mapped sweep succeeds. `new_commits` therefore keeps dispatching successive batches until that sweep completes. `timer` dispatches solely from `last_run_at` age.

## Safety invariants

- Patrol is opt-in at the scheduler gate AND at config resolution: a missing patrol section, a missing `mode:`, `patrol.mode: off`, or `patrol.enabled: false` all leave patrol disabled and prevent daemon dispatch, and the daemon still requires `daemon.enabled`.
- Findings surface as PRs, and opened PRs enter `6-review` by default; patrol still never writes `1-inbox/` intake tasks.
- A new sweep scans the exact freshly fetched remote default without moving the operator's local branch; configured-remote fetch failure stops before mapper/reviewer work. PR creation separately re-fetches the default for structured fresh-base reproduction/root-cause proof, configured validation, and secret scanning, so an older pinned review snapshot cannot become an old-base patch.
- Synthetic `6-review` handoff requires exact hosted base/head identity plus a final live remote base/head check for both first attempts and retries; a stale-base or raced-base PR cannot create a patrol review task.
- A non-dry-run cycle requires at least one configured validation command before mapping, review, or state mutation. `--dry-run` remains review-only and bypasses that preflight.
- Each semantic root maps to at most one active or merged PR, an open PR blocks additional variants from the same feature, and one feature normally supplies at most one fix per cycle.
- A failed patrol-to-review handoff is not treated as an active fingerprint state, so later patrol cycles can retry instead of losing the opened PR from the review queue; an exact existing synthetic task is reconciled instead of duplicated.
- Closed-unmerged patrol PRs become dismissals and are skipped on future cycles.
- Agent prompts treat findings and recommendations as data; validation commands come only from project config.
- Review launches are admitted only with conservative initial-context headroom,
  use a bounded provider tool context, and stop after the completed artifact or
  three Claude turns; the structured parser still fails closed on malformed or
  incomplete output.

## Backlinks

- [[commands/patrol]]
- [[commands/refactor-patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[modules/worktree]]
- [[modules/agent]]
