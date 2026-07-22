---
title: hive patrol
type: command
source: lib/hive/commands/patrol.rb, lib/hive/patrol/*
created: 2026-05-28
updated: 2026-07-19
tags: [command, patrol, review, pr, json]
---

**TLDR**: `hive patrol PROJECT [--dry-run] [--json]` runs one evidence-first production-defect scan for a registered project. It maps language-neutral components, rotates through a bounded review batch, rejects weak or misattributed findings atomically, globally ranks semantic root causes by deterministic alpha, diversifies fixes across components, and independently proves fail-before/pass-after behavior before configured validation can open a PR. Patrol state lives under `<project>/.hive-state/patrol/`; findings never go through `1-inbox/`, and opened PRs enter normal `6-review` through synthetic `Patrol: ...` tasks carrying the observed proof.

## Usage

```bash
hive patrol my-project
hive patrol my-project --dry-run
hive patrol my-project --json
```

`PROJECT` is a registered project name from the global config. The project must opt in through `<project>/.hive-state/config.yml`:

```yaml
patrol:
  enabled: true
  trigger: continuous
  agent: claude
  min_confidence_to_fix: medium
  min_alpha_to_fix: 70
  max_findings_per_feature: 3
  max_features_per_cycle: 12
  max_fixes_per_feature_per_cycle: 1
  max_fix_attempts_per_cycle: 6
  max_prs_per_cycle: 3
  fix_budget_multiplier: 2 # per-agent fix headroom; cycle/day limits stay shared
  draft_prs: false   # default: open ready PRs (the babysitter skips drafts). Set true to open draft PRs.
  review_prs: true    # default: enqueue each opened patrol PR into 6-review as "Patrol: ..."
  review:
    reviewers:
      - name: codex-native-review  # default patrol PR reviewer: native codex review, no CE skill
        kind: codex_review
        agent: codex
        output_basename: codex-native-review
        prompt_template: reviewer_codex_native_review.md.erb
        timeout_sec: 5400
  commands:
    test: bundle exec rake test
```

`patrol.trigger` accepts three modes (default `continuous`):

- `continuous` (default) is the hybrid mode: it runs when either the default branch moved or the timer interval elapsed, so patrol can keep mining existing slices between merges while still reacting to fresh `main` changes.
- `new_commits` runs only when the default branch SHA differs from `last_scanned_sha`.
- `timer` runs whenever `last_run_at` is older than `poll_interval_sec`.

The higher-level `patrol.mode` also resolves bounded resource envelopes. Low, medium, high, and ultrapatrol allow respectively 1/3/6/10 agent launches and 100k/200k/400k/800k measured tokens per ordinary cycle, with separate 2/8/18/36 ordinary-launch and 200k/600k/1.2m/2.4m shared-token ceilings per UTC day. Their ordinary review per-launch streamed-token limits are 40k/50k/75k/100k. Ordinary fixes receive `fix_budget_multiplier` times that per-agent headroom (2x by default) for edit/test/proof turns without enlarging cycle or day totals. Architecture receives 2x the ordinary per-launch token limit and 2x the per-cycle launch/token envelope; its fix does not compound the ordinary fix multiplier. Metered architecture launches are counted separately and do not consume the ordinary daily launch quota. Unmetered architecture launches use the independent `max_architecture_unmetered_spawns_per_day` safety cap (default `96`). The native `max_budget_usd_per_agent` guard and project/day token ceiling stay shared. One project-wide advisory lock is held for the complete lifetime of each ordinary or architecture agent, so concurrent patrol workers cannot both spend the same daily headroom; a competing launch fails closed as `agent_in_flight` and can be retried by its scheduler. Claude stream events enforce the cap during a run; providers without interim usage remain bounded by launch and wall-clock ceilings and are recorded as unmetered when no terminal count exists. The CLI field is named `max_budget_usd_per_agent`, but for subscription-backed agents it is a subscription runaway guard expressed in budget-equivalent units, not an additional payment.

## Steps

Before a normal run, Hive requires at least one configured `docs`, `format`,
`lint`, `public_contract`, `typecheck`, or `test` command. Missing validation
fails as a configuration error before patrol state, repository mapping, or any
reviewer/fixer agent is created.

1. Reconcile dismissal memory for existing patrol branches and PRs.
2. For a new sweep, strictly fetch the explicit remote head `refs/heads/<default_branch>` into `origin/<default_branch>` and materialize its exact commit as a clean detached scan checkout. A same-named tag cannot shadow this branch, and the fetch has a bounded process-group deadline. A configured remote that cannot be fetched fails the cycle before mapper or reviewer work instead of falling back to stale local main; repositories without an `origin` use their local default branch. The registered checkout's current branch, dirty files, local-default position, and concurrent edits cannot contaminate or be moved by the scan. Map that snapshot's tracked source into non-overlapping language-neutral component/manifest features, subsystem tests, and separate command-contract slices. Each command path is a primary evidence anchor only in its command slice and remains supporting context in its component; all scripts in one manifest share one contract review, and that manifest is not reviewed again as a generic component. Generic text source under common code roots remains mappable without a language adapter; the old overlapping route/package/monolithic-test slices are not emitted in this mode.
3. Select a deterministic batch of at most `max_features_per_cycle` features, further bounded by the tighter remaining ordinary cycle or shared UTC-day launch headroom. A shipping run reserves as many available launches as possible up to `max_fix_attempts_per_cycle`, while still reviewing at least one feature; `--dry-run` may use the whole remaining envelope because it cannot fix. An explicit active marker, cursor, and exact snapshot SHA persist across daemon cycles, including a failed first batch whose cursor is still zero. A later feature error advances the cursor past the batch's proven-clean prefix and pins the first failed feature; an unattributable error still fails closed at the batch start. If the remote default advances during an incomplete or errored sweep, Hive finishes the stored review snapshot before starting the newer one, bounding reviewer cost without permanently restarting at the first component. If the saved commit is no longer materializable, Hive fetches the current default and restarts the feature cursor instead of retrying a dead snapshot forever. A stored review pin cannot produce an old-base branch or task: step 6 independently re-fetches immediately before every fix, and steps 8–9 require exact base/head identity before handoff.
4. Ask the configured agent for at most three production findings per feature. Its initial source view contains at most four owned paths selected under a 32 KiB budget; context and test paths require the single hypothesis-driven follow-up. The third response must write JSON, with a fourth turn available only for emergency finalization. The bounded response is accepted all-or-nothing: every admitted record requires a current-checkout contract, consequence, root cause, reproduction/static trace, targeted validation, and repository-confined production evidence whose cited line contains the supplied snippet. The trigger/root-cause anchor must belong to the mapped slice. Zero findings is explicitly preferred to speculation. Documentation, test-gap, and maintainability belong outside ordinary auto-fix patrol.
5. Compute a 0–100 alpha score from production category, grounded scope, complete defect proof, evidence breadth, and prior dismissal outcomes. Severity and confidence remain admission gates and small tie-breakers because the historical corpus showed their model-authored labels did not predict delivery. Skip dismissed, already-PR'd, similar-known, low-confidence/severity, non-production, low-alpha, already-active-feature, same-run semantic duplicate, and over-feature-budget findings. Historical aliases map legacy command/route/package slice IDs to their equivalent current component without treating unrelated old surfaces as active. Rank the survivors globally; mapper order no longer decides the PR budget.
6. For each ranked survivor, strictly fetch the default branch (no stale-local fallback) and create `hive-patrol/...` from its exact commit. The fixer prompt directs four bounded inspect/reproduce/edit/proof responses and tells the agent to leave post-edit validation to Hive. It selects an operator-configured validation key and declares bounded, confined sibling-audit and regression paths, which may use any language or project-specific directory. A completed `fix.json` ends the agent phase even when a later provider token/turn boundary fires, but it does not validate or publish the edits. Hive reads that proof as a nonblocking, no-follow, regular file capped at 64 KiB, overlays only those changed regression files onto an isolated base, requires a normal nonzero failure that identifies one of them, then requires the same configured command to pass on the patched tree. Both the base proof and patched validation honor `timeout_sec.patrol`, so a project suite is not cut off by the validator's fallback default. Agent-authored root-cause/audit prose remains explicitly reported context, not machine proof; rejection does not permanently suppress the finding.
7. Run the broader operator-configured validation commands only after the reproduction gate. `max_prs_per_cycle` caps PRs **opened**, while `max_fix_attempts_per_cycle` independently bounds expensive fixer calls when candidates are stale, rejected, or fail validation. A structured cycle/day quota exhaustion stops the remaining attempts immediately.
8. Open a PR only when validation passed, the changed paths pass the review fix guardrail, and title, body, and the exact validated base-to-head diff pass secret scanning. The local head/cleanliness, remote base, leased branch push, remote head, and created PR identity are checked fail-closed. Immediately after creation Hive records `reconciliation_pending` with the exact PR URL and patch/base/head/worktree receipt; lookup lag, authentication failure, or restart reuses only that validated patch. The fingerprint becomes `open` only after exact URL/base/head reconciliation and review handoff settle.
9. Unless `patrol.review_prs: false`, keep the patrol worktree and create a synthetic `.hive-state/stages/6-review/patrol-.../` task with display name `Patrol: <finding title>`, `task.md`, `worktree.yml`, `pr.md`, and `reviews/`, so the normal daemon/TUI review flow picks it up. Handoff occurs only after the created or retried PR reports the exact validated head, default-branch name, and base OID, followed by one final live remote head/base check immediately before task publication. A failed handoff retry whose base has advanced therefore cannot create a stale-base review task. The PR body and `task.md` carry the observed before/after result and label root-cause text as agent-reported. A failed handoff preserves and reuses the exact validated patch rather than rebuilding a different commit. Patrol tasks use `patrol.review.reviewers` instead of the normal `review.reviewers`; fresh projects default that list to `codex-native-review` (`kind: codex_review`), with Codex/Claude CE `ce-code-review` entries as init-time opt-ins.
10. Persist `last_run_at`, the active-snapshot marker, batch cursor, exact reviewer errors, and closed per-attempt outcomes. `last_scanned_sha` advances only after every feature in the SHA-bound sweep has been reviewed; reviewer contract failures remain visible, pin the attempted SHA at the first failed feature (including cursor zero), and leave the unfinished suffix eligible for retry.

`--dry-run` bypasses the validation-command preflight because it cannot ship
code, then stops after map + review + scored candidate selection. It updates
scan/audit state but does not create fix worktrees, push branches, or open PRs.

## Alpha calibration

The 2026-05-12 through 2026-07-12 audit found 218 generated `Hive patrol:` PRs: 144 merged, 65 closed unmerged, and 9 open. All 218 came from only nine legacy slices; seven command/test slices produced 211. In the June 1–20 subset, 48 of 53 closed PRs were explicitly duplicate, redundant, or superseded. Repeated root-cause families included implicit GitHub POST mutations, JSON option grammar, signature/helper execution, browser/pager launch paths, eval confinement, and filesystem/process boundaries. High model-authored confidence did not predict delivery: only 17 of 41 high-confidence June findings with retained metadata merged.

That evidence drives the current policy: component ownership instead of overlapping sibling/test slices; one review for each command or manifest contract; semantic identity independent of feature wording; global impact/evidence/novelty ranking; one normal fix per component per cycle; bounded fixer attempts; immutable finding/selection records; and “smallest complete root-cause fix” rather than a one-variant micro-patch. Large architecture or maintainability opportunities remain Architecture Patrol theses rather than ordinary defect PRs.

## JSON

With `--json`, the command emits a single `hive-patrol.v2` envelope (`hive-patrol.v1` remains pinned for older consumers):

```json
{
  "schema": "hive-patrol",
  "schema_version": 2,
  "ok": true,
  "project": "my-project",
  "project_root": "/home/me/Dev/my-project",
  "dry_run": false,
  "features_mapped": 4,
  "features_review_attempted": 4,
  "features_reviewed": 4,
  "review_complete": true,
  "review_errors": [],
  "findings": 2,
  "fix_candidates": 1,
  "fixes_attempted": 1,
  "fixes_validated": 1,
  "prs_opened": 1,
  "pr_urls": ["https://github.com/org/repo/pull/123"],
  "review_handoff_errors": [],
  "fix_results": [
    {
      "finding_id": "review-1-1",
      "patch_id": "patch-1",
      "passed": true,
      "reason": "validated",
      "detail": null,
      "patch_artifact": ".hive-state/patrol/patches/patch-1.json",
      "publication_status": "opened",
      "publication_reason": null,
      "publication_detail": null,
      "pr_url": "https://github.com/org/repo/pull/123"
    }
  ],
  "skipped_findings": [],
  "last_scanned_sha": "abc123"
}
```

If patrol creates a PR but cannot immediately prove its exact hosted identity, `reconciliation_pending` preserves its URL and validated publication receipt without treating the finding as active or rerunning the fixer. If it proves the PR but cannot create its synthetic `6-review` task, the PR URL appears in `review_handoff_errors` and the exact validated worktree/patch is retained for a handoff-only retry. `review_errors` distinguishes malformed/failed feature reviews from a clean zero-finding result; `review_complete` becomes true only after the full pinned snapshot sweep succeeds. Each reviewer evidence `snippet` must be an exact, non-empty substring of the one source line named by its repository-relative `file` and positive `line`; multiline excerpts, ellipses, and explanatory annotations are invalid, and one invalid evidence item rejects the complete finding. The reviewer prompt states this same byte-verification contract so source-backed findings reach the validator without weakening its hallucination guard. A token-limited review retains `details.resource_exhaustion` with reason, configured limit, and observed count instead of flattening the cap into prose. Fix, publication, and skip reasons are closed enums, with dynamic diagnostics separated into nullable detail fields. Selection decisions are also written as immutable `runs/selection-*.json` audit records.

Config errors emit `ok: false`, `error_kind: "config"`, and exit 78. A missing `PROJECT` is rejected by Thor before `Hive::Commands::Patrol` runs; when `--json` is present, `bin/hive` maps that pre-dispatch usage error to a `hive-patrol` error payload with `error_kind: "error"` and exit 64 so patrol callers still receive one schema-shaped JSON document.

## Daemon

The always-on behavior comes from [[modules/daemon]]: `Hive::Daemon::PatrolScheduler` checks opt-in projects on a slow cadence and returns `hive patrol <project> --json` dispatches. The dispatcher still applies `daemon.enabled`, legacy-layout, dry-run, and concurrency gates before spawning the child.

## Backlinks

- [[modules/patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[cli]]
