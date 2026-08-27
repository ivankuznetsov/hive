---
title: 4-execute stage
type: stage
source: lib/hive/stages/execute.rb, templates/execute_prompt.md.erb
created: 2026-04-25
updated: 2026-08-20
tags: [stage, execute, worktree, plan-review]
---

**TLDR**: Implementation-only since U9 (ADR-014). Entry from built-in coding plan first requires a current [[modules/plan_review]] resolution; raw movement into execute revalidates existing review evidence and writes a compatibility receipt only for a task with no review root. First implementation entry creates a feature worktree at `<worktree_root>/<slug>`, records its baseline HEAD in `worktree.yml`, spawns the implementation agent, captures its final message into `task.md`, and finalises with `EXECUTE_COMPLETE` only when the worktree stays on the task branch, descends from the baseline, has a new commit, and is clean. Clean no-change exits pause as `EXECUTE_WAITING reason=no_worktree_changes` unless `plan.md` opts into `execution_mode: research` and the agent produced a structured final answer. Provider quota walls write `ERROR reason=limits_reached`; typed non-limit provider failures and agent-owned dirty progress also become recoverable errors. The daemon submits each exact error generation to `RecoveryCoordinator` after the shared cooldown instead of hot-looping. The user `mv`s completed tasks to `6-review/` to enter the autonomous review loop. No PR review/iteration logic lives in 4-execute — that all moved to [[stages/review]].

## Condition boundary

Every mutating completion boundary reconciles exact HEAD/diff and durable
attempt health, appends one authoritative observation batch, publishes its
bound projection, evaluates the versioned execute gate, then writes the
compatibility marker. Coding success requires current-attempt/current-HEAD
`ChangesPresent=satisfied` and no active `AwaitingHuman`; `AgentHealthy` is
required while agent-owned work is active and informational after a durable
terminal outcome. Research records no-change honestly and succeeds only via
the declared waiver plus output evidence.

Missing evidence triggers one inline reconciliation, then fails closed if
still pending/unverifiable. Success, all worktree waits, provider/agent failure,
and git observation failure use this ordering. Approve, stage-action, and run
report paths share the transition guard. See [[modules/conditions]].

## Generation-scoped implementation owner

Before execute creates its reviews directory, feature worktree, pointer, or initial task marker, `Hive::ImplementationIdentity::Store#capture_execute!` runs under the durable attempt context. It resolves provider, concrete model, launcher/profile identity, source, generation, originating attempt, requested/effective execute effort, and effort support; appends `implementation_identity_captured`; rebuilds the projection; and only then permits stage initialization and the spawn. Invalid effective routing or journal failure therefore leaves execute state untouched. The journal and projection are included in the protected-file snapshot after capture, so an implementation process with task-folder access cannot rewrite its durable owner unnoticed. Equivalent retries are idempotent, while a conflicting second identity for the same generation fails closed.

Crash/provider retries, daemon adoption, restart, and project config edits stay within the generation and reuse the captured identity, including failure-marker provider attribution. An accepted input change through the generation tracker advances the epoch, after which execute may capture a new owner while history remains queryable. Legacy reconstruction is allowed only at a mutating implementation boundary: structured durable attempt metadata from the exact project/task/generation wins over sanitized launcher argv, which wins over explicit current execute config. Config fallback appends a visible warning and one `legacy_backfill`; status reads never invoke reconstruction. Downstream attempt admission treats only an absent journal as legacy generation zero; malformed, unreadable, empty, or attempt-unbound journals fail closed.

## Setup

- **State file**: `task.md` with frontmatter `slug`, `started_at`. Initial body has `## Implementation` heading plus `<!-- AGENT_WORKING -->`.
- **Worktree pointer**: `worktree.yml` (created on init pass; gates re-entry).
- **Plan precondition**: `plan.md` must exist; otherwise stderr `"plan.md missing; this task did not pass through 3-plan"` and exit 1. For built-in coding tasks, `PlanReview::TransitionGuard.validate_execute_entry!` also requires current `skipped`, `cleared`, or `degraded_cleared` evidence whenever a review root exists. A no-root task already at execute receives `plan-review/legacy-execute-adoption.json` and is not retroactively blocked.

## Pre-flight state machine (`task_state`)

| Marker / State | Action |
|----------------|--------|
| `:execute_complete` | print `"already complete; mv this folder to 6-review/"`, return |
| `:execute_waiting` | re-run the implementation pass after the user reviews a true input/evidence pause; an attributed legacy `dirty_worktree` wait is upgraded automatically to recoverable `ERROR` |
| `:error` | warn with attrs; user investigates, clears marker |
| `worktree.yml` exists but path missing | warn `"worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"`, exit 1 |
| no `worktree.yml` | run **init pass** |
| `worktree.yml` exists, healthy | re-running on a complete task says "already complete; mv to 6-review/" |

`EXECUTE_WAITING` is written for implementation-output or evidence pauses: `reason=no_worktree_changes` when the agent exits cleanly without a baseline-descendant commit, `reason=missing_research_output` when a research-mode plan has no structured final message, `reason=branch_mismatch` when the worktree is detached or on the wrong branch, and `reason=head_not_descendant` when HEAD no longer descends from the execute baseline. Current uncommitted agent progress writes `ERROR reason=dirty_worktree`. The daemon upgrades historical `EXECUTE_WAITING reason=dirty_worktree` rows only when they carry a durable `attempt_id`; unattributed legacy dirt remains a human pause. `EXECUTE_STALE` review-iteration state moved to `REVIEW_STALE` in 6-review.

## Init pass (`run_init_pass`)

1. Resolve and profile-validate the generation's effective implementation identity.
2. `Worktree.new.create!(slug, default_branch: ...)` runs `git worktree add <root> -b <slug> <default>` (or attaches to an existing branch if it already exists).
3. `Worktree.validate_pointer_path` rejects worktrees outside the configured `worktree_root` prefix.
4. `Worktree#write_pointer!` writes `worktree.yml`, including `execute_base_head` for later baseline checks.
5. `write_initial_task_md`.
6. `spawn_implementation`.
7. Capture the agent's final stdout / stream-json result into `task.md` under `## Execute Output`.
8. SHA-256 protect pass on `plan.md` / `worktree.yml`.
9. Verify the worktree is on the expected task branch, descends from `execute_base_head`, is clean, and either has a new baseline-descendant commit or is an explicit `execution_mode: research` plan with a structured final agent message.
10. `EXECUTE_COMPLETE`, a true `EXECUTE_WAITING reason=...` input pause, or a recoverable `ERROR`.

Re-running with `worktree.yml` already present and a `:execute_complete` marker is a no-op announcing 6-review.
An automatic retry after `ERROR` resumes the exact owned worktree even when it
contains uncommitted edits from the failed agent. Those edits are durable
implementation progress; ownership, branch, ancestry, and tamper checks still
run. If a successful ordinary implementation exit leaves in-scope residue, the
generic stage-exit CleanExit hook auto-commits it and immediately reuses
Execute's owned-worktree, expected-branch, descendant-commit boundary to publish
`EXECUTE_COMPLETE` in the same run. Research-mode execution keeps its separate
final-message evidence contract. Residue that CleanExit cannot safely commit remains
`ERROR reason=dirty_worktree`, so retry backoff and lineage stay scheduler-owned.
The explicit `hive worktree commit-residue --complete-execute` recovery path can
snapshot that whole implementation even when planned files fall outside the
review-fix filename allowlist, while retaining staged-symlink, secret-content,
signing, ownership, branch, ancestry, and cleanliness gates.

## Implementation sub-agent (`spawn_implementation`)

- **Prompt**: `templates/execute_prompt.md.erb` rendered with `project_name`, `worktree_path`, `task_folder`, `plan_text`. Plan is wrapped in `<user_supplied content_type="plan_md">`.
- **cwd**: feature worktree (so `claude` picks up the project's CLAUDE.md from there).
- **`--add-dir <task folder>`**: lets the agent read plan.md and append to `task.md` ("## Implementation" section).
- **Budgets**: `cfg["budget_usd"]["execute_implementation"]` (100), `cfg["timeout_sec"]["execute_implementation"]` (2700).
- **Log label**: `execute-impl`.
- **Final message capture**: `Hive::Agent` records the last `result`, `item.completed agent_message`, `assistant` stream-json message, or plain stdout tail. `Stages::Execute` writes it to `task.md` before the terminal marker so investigation work is not trapped only in raw logs. Only structured final messages count as research-mode output; plain stdout/stderr progress is preserved but does not complete research mode.
- Agent must commit each logical unit in the worktree and run lint/tests as it goes. May only edit `task.md` inside the task folder; must not touch `plan.md` or `worktree.yml` (SHA-256 protected, ADR-013).
- The firewall also protects the task journal/projection and every promoted
  `context-receipts` and `activity-operations` record. Because those immutable
  histories grow on retries, Execute partitions them into manifests of at most
  128 anchors and nests the manifests around the same single provider call;
  no receipt is dropped from custody and the global per-manifest bound remains
  unchanged. The protected-anchor set itself is capped at 16 manifests and
  rejects required-output policies; a custody validation failure leaves task
  state untouched instead of writing through an unsafe boundary.
- If the implementation spawn exits with provider-limit text in `limit_text` or `error_message`, `run_pass` writes `ERROR reason=limits_reached provider=<execute-agent> message="implementer hit a usage/credit limit" retry_after=<iso8601>` and returns `commit=limits_reached`. Complete dated provider reset hints are preserved into `Hive::AgentLimit.retry_after`; ambiguous or absent hints use the fixed cooldown. Pi and other typed stream extractors can fail a provider turn even when the CLI exits zero; non-limit failures return `error_reason=provider_error`, then Execute writes `ERROR reason=implementer_failed status=error message=<redacted provider diagnostic>`. An exception before the agent can return a typed result also writes that recoverable marker with `status=exception`, a bounded redacted message, and the exception class before the exception continues to the durable attempt receipt. Tamper evidence retains precedence. The retry boundary is shared with `StaleAgentHealer` and documented in [[state-model]] and [[modules/daemon]].
- Normal success requires the worktree to remain on the branch from `worktree.yml`, HEAD to descend from `execute_base_head`, the worktree to be clean, and at least one new baseline-descendant commit. A clean no-commit exit pauses as `EXECUTE_WAITING reason=no_worktree_changes`; a dirty worktree writes recoverable `ERROR reason=dirty_worktree`; detached/wrong-branch commits pause as `reason=branch_mismatch` or `reason=head_not_descendant`.
- Research-only execution is explicit: `plan.md` YAML frontmatter must include `execution_mode: research`. In that mode a clean no-commit exit can complete, but only if the final message was captured; otherwise it pauses as `EXECUTE_WAITING reason=missing_research_output`.

## Tests

- `test/unit/agent_test.rb` — captures final messages from stream-json result lines.
- `test/unit/stages/execute_test.rb` — pins execute's provider-limit classification via both `error_message` and raw `limit_text`, typed and exceptional `implementer_failed` markers, tamper precedence, and bounded custody of growing controller-receipt history.
- `test/integration/run_execute_test.rb` — init pass produces `EXECUTE_COMPLETE`; no-change exits preserve `## Execute Output` and pause; research-mode no-change runs can complete with output; research-mode without output pauses; re-run announces 5-open-pr; tampering → `:error`; impl failure → `:error`; missing plan.md exits 1; no review files written.

## Backlinks

- [[stages/plan]] · [[stages/open-pr]] · [[stages/review]]
- [[modules/worktree]] · [[modules/agent]] · [[modules/markers]] · [[modules/git_ops]] · [[modules/findings]] · [[modules/plan_review]]
- [[commands/findings]] — list and toggle the `[x]` accepted-flag on findings this stage produces
- [[state-model]] · [[decisions]]
