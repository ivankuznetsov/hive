---
title: 5-review stage
type: stage
source: lib/hive/stages/review.rb, lib/hive/stages/review/{ci_fix,triage,browser_test,fix_guardrail}.rb, templates/{fix,ci_fix,browser_test,triage_*}*.erb
created: 2026-04-26
updated: 2026-04-26
tags: [stage, review, autonomous-loop, ci, triage, fix-guardrail]
---

**TLDR**: The autonomous review loop. After 4-execute commits the implementation, the user `mv`s the task to `5-review/`. `Hive::Stages::Review.run!` runs CI on entry, then loops `reviewers → triage → fix` until the branch is clean (or hits a budget cap) and finalises with a browser-test phase. One `hive run` either lands a terminal marker (`REVIEW_COMPLETE`, `REVIEW_WAITING`, `REVIEW_CI_STALE`, `REVIEW_STALE`, `REVIEW_ERROR`) or exhausts per-spawn budgets — never an in-progress state the user has to reconcile.

## Setup

- **State file**: `task.md` with the same frontmatter that 4-execute wrote (`slug`, `started_at`). The runner does NOT track pass count in frontmatter — it derives the current pass by reading `reviews/<reviewer-name>-<NN>.md` filenames and taking the maximum NN.
- **Worktree pointer**: `worktree.yml` (carried over from 4-execute; missing → exit 1 with "5-review entered without a worktree.yml").
- **Reviews directory**: `reviews/` (carried over). New per-pass files written here: `<reviewer>-NN.md`, `escalations-NN.md`, `ci-blocked.md` (Phase 1 hard-block), `browser-blocked-NN.md` (Phase 5 warned), `fix-guardrail-NN.md` (post-fix tripped).

## Pre-flight (`Review.run!`)

| Marker / State | Action |
|----------------|--------|
| `:review_complete` | print "already complete; mv this folder to 6-pr/", return |
| `:review_ci_stale` | warn; user fixes CI then `hive markers clear FOLDER --name REVIEW_CI_STALE` and re-runs |
| `:review_stale` | warn; user clears/re-runs if highest pass lacks `escalations-NN.md`, otherwise trims `reviews/` then clears/re-runs |
| `:review_error` | warn with attrs; user investigates then `hive markers clear FOLDER --name REVIEW_ERROR` and re-runs |
| `:review_waiting` | resume — skip Phase 2/3, jump straight to Phase 4 with the user's manually-ticked `[x]` marks |
| no `worktree.yml` | exit 1 (must come from 4-execute) |
| `worktree.yml` points at deleted path | exit 1 with `git worktree prune` recovery hint |

## The pass loop

```
Phase 1 (CI fix)         once on entry
Phase 2 (reviewers)      sequential, one adapter per spec in cfg.review.reviewers
Phase 3 (triage)         courageous (default) | safetyist | review.triage.custom_prompt
branch on triage:
  any [x]                → Phase 4 (fix) → loop to Phase 2 with pass++
  escalations only       → REVIEW_WAITING escalations=N pass=NN (terminal)
  all clean              → Phase 5 (browser test) → REVIEW_COMPLETE
```

Pass cap (`review.max_passes`, default 4) gates re-entry to Phase 2 — exceeding it sets `REVIEW_STALE pass=NN`. Wall-clock cap (`review.max_wall_clock_sec`, default 5400) is checked at every phase boundary AND between reviewers inside `run_reviewers` (so the adapter-local retry budget cannot drain the whole 5400s window inside one Phase 2 invocation); exceeding it sets `REVIEW_STALE reason=wall_clock`.

## Phase 1 — CI fix (`Hive::Stages::Review::CiFix`)

Runs `cfg.review.ci.command` (e.g., `bin/ci`) once on entry. The subprocess is launched with `Process.spawn(pgroup: true)` and its combined stdout+stderr is **streamed** through a reader thread with a 256 KB byte-cap applied during read (so a runaway CI cannot OOM the host before the cap kicks in). A per-process timeout from `cfg.timeout_sec.review_ci` (default 600s) bounds wall time: on expiry the pgid is TERM'd, given a 3s grace, then KILL'd, and the resulting `CommandError` falls through the existing `:error` path. On red exit, the captured log is ANSI-stripped, tail-truncated to the configured line cap, and fed to a fix agent through the per-spawn `<user_supplied>` nonce wrapper. Re-runs CI. Up to `review.ci.max_attempts` (default 3); cap reached → `:stale` → runner writes `reviews/ci-blocked.md` and sets `REVIEW_CI_STALE`. Reviewers do NOT run on red CI.

`review.ci.command` is project-specific by design — hive doesn't ship a Rubocop/Brakeman driver because that would couple the orchestrator to one ecosystem. The user owns the contract; hive shells out and parses exit code + last-N lines.

## Phase 2 — reviewers (`Hive::Reviewers::Agent`)

For each spec in `cfg.review.reviewers`, sequentially: dispatch via `Hive::Reviewers.dispatch(spec, ctx)`, run through `Hive::Agent.run!` with the spec's profile, write `reviews/<output_basename>-<NN>.md`.

Per-reviewer failures retry up to `max_attempts` (default `Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS = 2`; configurable on each reviewer spec) with exponential backoff capped at 8s (1s, 2s, 4s, 8s, 8s, …). After retries are exhausted, the failure is recorded as a one-line entry in `reviews/errors-NN.md` (an orchestrator-owned file — see `ORCHESTRATOR_OWNED_PREFIXES`); the reviewer's own per-pass output file stays absent so `discover_reviewer_files` correctly reports "this reviewer produced nothing this pass" instead of triaging an infra-failure stub as a real `[ ]` finding. `errors-NN.md` is unconditionally deleted at the start of every `run_reviewers` invocation and re-created on the first failure within that invocation (append-with-header-on-first-write thereafter), so a marker-clear-and-rerun that succeeds leaves no file behind and one that re-fails shows only the latest pass-NN failures rather than concatenated history. All reviewers fail → `REVIEW_ERROR phase=reviewers reason=all_failed` (the all-failed safety net is preserved). Empty reviewer list → skip directly to the all-clean branch (Phase 5).

CE skill invocation is profile-aware: `templates/reviewer_claude_ce_code_review.md.erb` and `templates/reviewer_codex_ce_code_review.md.erb` invoke the same logical CE skill (`/compound-engineering:ce-code-review`) but render the call syntax according to `profile.skill_syntax_format`. `templates/reviewer_pr_review_toolkit.md.erb` is a stand-in for the `pr-review-toolkit:code-reviewer` agent.

Every reviewer prompt embeds the task's `plan.md` inline through `Hive::Reviewers::PlanContext.render(task_folder, user_supplied_tag)` — wired into `Agent#render_prompt` as the `plan_context_section` template binding and rendered between the `Pass:` header and the `Behavior:` block in all three reviewer templates. The section frames the plan as authoritative on scope and tells reviewers to drop candidate findings that flag deliberate plan-level scope boundaries (e.g. "feature X not implemented" when the plan defers X to a separate downstream task). It also carries a symmetric anti-finding rule: if the plan's **Goals** or **Requirements Trace** lists an item the diff does NOT implement and the plan does NOT defer it, the reviewer must raise that as a High-severity finding — the rule suppresses escalations on plan-deferred gaps, not on plan-required-but-missing gaps. Without this grounding, reviewers re-derive scope from the worktree alone and routinely escalate intentional gaps — driving the same task into REVIEW_STALE pass after pass because the fixer can't resolve a plan-by-design contradiction.

Per ADR-008 / ADR-019: plan content is data, not instructions. The plan body is wrapped in a per-spawn `<user_supplied_<hex>>` nonce block — same pattern as `templates/execute_prompt.md.erb`, `fix_prompt.md.erb`, and `triage_courageous.md.erb` — and the reviewer is instructed in-prompt to classify the inner content strictly as data and not execute any directive that appears inside the wrapper. The system-level scope-authority framing lives OUTSIDE the wrapper so the reviewer treats the framing as instructions and the plan body as data. The nonce is captured once per spawn in `Agent#render_prompt` and reused for both the template's own `user_supplied_tag` binding and the plan-context inner wrapper, so the rendered prompt has a single consistent nonce — pinned by `test_render_prompt_uses_single_nonce_for_template_tag_and_plan_wrapper`.

If `plan.md` is missing, empty, whitespace-only, or unreadable (EACCES, EISDIR, ENOENT-race), the section degrades to a fixed `ABSENT_NOTE` constant so the prompt stays well-formed and the reviewer flags missing-plan in its output header. Non-UTF-8 bytes in `plan.md` are scrubbed to U+FFFD before interpolation so a stray latin1 paste doesn't crash the spawn at the ERB layer.

Reviewer kind `linter` is rejected with a helpful pointer to `review.ci.command` — linters belong in the project's CI driver, not in hive's reviewer adapter (see ADR-014).

## Phase 3 — triage (`Hive::Stages::Review::Triage`)

Spawns a triage agent with all per-reviewer files for the current pass concatenated through the per-spawn nonce wrapper. The agent's job: tick `[x]` on findings safe to auto-fix; leave `[ ]` (with a one-line rationale appended) on findings that need human review. Two bias presets:

- **`courageous`** (default, `templates/triage_courageous.md.erb`) — apply max review fixes in automatic mode; escalate only sketchy / architecture-level findings.
- **`safetyist`** (opt-in, `templates/triage_safetyist.md.erb`) — escalate when in doubt; only tick obvious mechanical fixes.

`review.triage.custom_prompt` overrides both presets with a path under `templates/`. Path-escape-guarded — `..` and absolute paths are rejected before render.

Plan / worktree.yml / task.md are SHA-256 protected around the triage spawn (ADR-013); tampering yields `REVIEW_ERROR phase=triage reason=triage_tampered`.

Escalations land in `reviews/escalations-<NN>.md` — every line that triage left as `[ ]` gets copied here as a digest for the user.

## Branching after triage

- `accepted.empty? && escalations.zero?` — Phase 2 produced zero findings — jump to Phase 5 (browser test).
- `accepted.empty? && escalations > 0` — Pause for user gate: `REVIEW_WAITING escalations=N pass=NN`. The user ticks `[x]` on whatever escalations they want fixed and re-runs; the runner detects `:review_waiting` resume, skips Phase 2/3, jumps to Phase 4.
- `accepted.any?` — Run Phase 4.

## Phase 4 — fix (`spawn_fix_agent`)

Spawns the fix agent (`cfg.review.fix.agent`, default `claude`) with the concatenated `[x]` lines from every per-reviewer file for the current pass, wrapped in the `<user_supplied>` nonce. The fix prompt requires git trailers on every commit (`Hive-Task-Slug`, `Hive-Fix-Pass`, `Hive-Fix-Findings`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`) — consumed by `hive metrics rollback-rate` (U14).

Plan / worktree.yml / task.md are SHA-256 protected around the fix spawn; tampering → `REVIEW_ERROR phase=fix reason=fix_tampered`.

After the fix agent returns, `Hive::Stages::Review::FixGuardrail.run!` (ADR-020 / U13) takes `git diff base..head` of the new commits and walks it once, dispatching each line to the configured pattern set:

- `shell_pipe_to_interpreter` — curl/wget pipe into sh/bash/python/ruby/node
- `ci_workflow_edit` — `.github/workflows/`, gitlab-ci, circleci, Jenkinsfile, bitbucket-pipelines, azure-pipelines, travis
- `secrets_pattern_match` — dispatches to `Hive::SecretPatterns.scan` (AWS, GitHub, OpenAI, Anthropic, Stripe, Slack, JWT, PEM, generic api_key)
- `dotenv_edit` — `.env`, `.env.<environment>` (e.g., `.env.local`, `.env.production`, `.env.test`, `.env.staging`), `secrets.yml`, `credentials.yml(.enc)`, `.npmrc`, `.pypirc`. Template suffixes are deliberately **excluded** so committed templates do not trip the guardrail: `.env.example`, `.env.sample`, `.env.template`, `.env.dist`, `.env.tmpl`, `.env.default`, `.env.defaults`. Projects that genuinely keep secrets in `.env.example` can re-add strict matching via `review.fix.guardrail.patterns_override` (custom `dotenv_template_edit` pattern).
- `dependency_lockfile_change` — Gemfile.lock, package-lock.json, pnpm-lock, yarn.lock, Cargo.lock, go.sum, poetry.lock, Pipfile.lock, composer.lock, uv.lock
- `permission_change` — `new mode 100755` raw-diff-header

Per-project override via `review.fix.guardrail.patterns_override`: `false` to disable a default; Hash to add a custom (must include `regex`). Tripped → `REVIEW_WAITING reason=fix_guardrail matches=N head=<sha> pass=NN` and `reviews/fix-guardrail-NN.md` written. The `head=` attribute records the worktree HEAD at the moment the guardrail tripped; the approval-on-resume path enforces it.

**Approval-on-resume (U5).** A user who reviews the fix-guardrail trip and decides the changes are intentional approves them by ticking `[x]` on every line of `reviews/fix-guardrail-NN.md` and re-running. The runner calls `fix_guardrail_approved?(ctx, expected_matches: marker.attrs["matches"].to_i)` and gates approval on **all four** of:

1. **All checkbox lines are `[x]`** — partial ticks keep the pause (no fall-through to Phase 4 fix re-spawn).
2. **Checkbox count matches `marker.attrs["matches"]`** — truncation-forged approval (user deletes the findings they didn't want to read) is rejected.
3. **`marker.attrs["head"]` matches the current worktree HEAD** — amend/rebase/squash between trip and approval is rejected with `REVIEW_ERROR phase=resume reason=approval_head_mismatch` (legacy markers without `head=`, written by hive ≤ PR-A round-2, skip this check with a stderr notice so in-flight tasks aren't broken on upgrade).
4. **Worktree is clean** — manual edits between trip and approval lead to `REVIEW_ERROR phase=resume reason=approval_dirty_worktree`.

When all four hold, Phase 2/3/4 are skipped for that pass — the prior pass's commits stand, `fix-success-NN.md` is written, marker resets, and the loop advances. **Special-case** for `pass == max_passes`: the approval breaks directly to Phase 5 (browser test) instead of incrementing into `REVIEW_STALE`. Approval is single-shot per pass: a future pass that re-trips the guardrail writes a fresh `fix-guardrail-(NN+1).md` with `[ ]` lines; pass-N approval does not transfer. The `fix-guardrail-NN.md` file is included in `protected_set` during every Phase 4 spawn (alongside `reviews/escalations-NN.md`, `reviews/errors-NN.md`, and the `fix-success-NN.md` sentinel) so a compromised fix agent cannot pre-write all-`[x]` lines to stage an approval token for the next resume.

If `marker.attrs["matches"]` is missing or malformed (not a positive Integer string) on a `fix_guardrail` marker, the runner refuses approval with `REVIEW_ERROR phase=resume reason=malformed_marker_matches` — disables a silent count-blind bypass.

## Phase 5 — browser test (`Hive::Stages::Review::BrowserTest`)

Only when Phase 2 produced zero findings (`pass=NN-1` was clean). Spawns the configured CE skill (`/compound-engineering:ce-test-browser` via `cfg.review.browser_test.agent`) which the agent invokes against the worktree. Returns one of `:passed`, `:warned`, `:skipped`, `:failed`. `:failed` is treated as `:warned` after `review.browser_test.max_attempts` (default 2) — the runner writes `browser-blocked-NN.md` and sets `REVIEW_COMPLETE browser=warned` rather than blocking the loop indefinitely.

`review.browser_test.enabled: false` skips the phase entirely; `:skipped` lands `browser=skipped` on the terminal marker.

## Stale-`REVIEW_WORKING` recovery (closes doc-review C-7 / ADV-12)

If the runner restarts on a `REVIEW_WORKING phase=X pass=N` marker with no live `.lock` holder, the prior run was interrupted. Recovery is per-phase, never mid-stream:

- **Interrupted at `phase=ci`** — re-run Phase 1 from scratch (idempotent).
- **Interrupted at `phase=reviewers`** — count `reviews/<*>-NN.md` for the current pass. If at least one exists, treat Phase 2 as complete-with-partial-results (missing reviewers get a stub `reviewer_failed` entry); proceed to Phase 3. If zero exist, re-run Phase 2.
- **Interrupted at `phase=triage`** — if `escalations-<pass>.md` exists, treat Phase 3 as complete; otherwise re-run (triage is idempotent — same reviewer files yield the same `[x]` marks under the deterministic stub).
- **Interrupted at `phase=fix`** — check `git log` for commits since the head of the current pass's reviewer files. Commits exist → treat Phase 4 as complete; loop with `pass++`. None → re-run Phase 4 (most fixes are file-level idempotent).
- **Interrupted at `phase=browser`** — re-run Phase 5 (idempotent).

The runner overwrites the stale marker as it enters the new phase. Resume entry-points are phase boundaries only.

## REVIEW_STALE recovery (max_passes / wall_clock)

`Stages::Review#pass_completion_status(folder, N)` classifies the highest-pass on disk as one of:

- **`:complete`** — `reviews/fix-success-NN.md` sentinel exists, OR pass `N+1` reviewer files exist. `next_pass_for` advances to `N+1`.
- **`:triage_incomplete`** — reviewer files for pass N exist but `escalations-NN.md` is missing. `next_pass_for` returns N; the loop re-runs Phase 2/3 to re-derive escalations.
- **`:fix_incomplete`** — reviewer files AND `escalations-NN.md` exist, but neither the sentinel nor pass `N+1` reviewer files exist. `next_pass_for` returns N; the loop **skips Phase 2/3** on the first iteration and runs Phase 4 directly on the operator's existing `[x]` marks (mirrors a `REVIEW_WAITING` resume).

The sentinel `reviews/fix-success-NN.md` is written by the runner at the two "pass N is done, advance" points: the Phase 2 zero-findings short-circuit to Phase 5, and post-guardrail-not-tripped continuation. `fix-success-` is in `ORCHESTRATOR_OWNED_PREFIXES` so it does not count as a reviewer file, and the current pass's sentinel path is protected during the fix-agent spawn so the agent cannot forge completion.

Recovery flow:

1. If the highest pass is `:fix_incomplete` (most common cause of `REVIEW_STALE` after a wall-clock or interrupted-fix exit): just `hive markers clear FOLDER --name REVIEW_STALE` and `hive run` — Phase 4 retries with the operator's already-applied `[x]` marks. The TUI's `recover_review` Enter binding does this automatically. No manual edit needed.
2. If `:triage_incomplete`: same — clear and rerun; the loop re-derives escalations from existing reviewer files.
3. If `:complete` (genuine `max_passes` exhaustion): inspect the highest-NN per-reviewer files; either edit them down (consolidate/trim findings) or rename the highest NN to a lower NN (drops the derived pass count). Then clear and rerun.
4. Wall-clock `REVIEW_STALE` (`reason=wall_clock`) can fire **before any reviewer files exist** (e.g. during Phase 1 CI-fix). The TUI treats this shape as auto-retryable regardless of disk state — give it more time via `review.max_wall_clock_sec` if it keeps timing out.

For `REVIEW_CI_STALE` (Phase 1 CI never went green) the equivalent flow is: edit `reviews/ci-blocked.md`, fix the CI failures locally, run `hive markers clear FOLDER --name REVIEW_CI_STALE`, then `hive run`. For `REVIEW_ERROR` (any phase failure recorded with `phase=…` and `reason=…`) the same pattern: investigate, run `hive markers clear FOLDER --name REVIEW_ERROR`, then `hive run`. The runner's pre-flight `warn` text emits the exact command per stuck-state.

No frontmatter edits required: pass count is filename-derived, not stored.

## Tests

- `test/integration/run_review_test.rb` — pre-flight short-circuits, missing-worktree handling, clean fast path, CI hard-block, wall-clock cap.
- `test/unit/stages/review/{ci_fix,triage,browser_test,fix_guardrail}_test.rb` — phase-level unit coverage.
- `test/unit/reviewers_test.rb`, `test/unit/reviewers/agent_test.rb` — adapter dispatch + agent-kind reviewer.
- `test/unit/metrics_test.rb`, `test/integration/metrics_command_test.rb` — `hive metrics rollback-rate` against trailered fixture commits.

## Backlinks

- [[stages/execute]] · [[stages/pr]]
- [[modules/markers]] · [[modules/agent]] · [[modules/config]]
- [[state-model]] · [[decisions]] · [[architecture]]
