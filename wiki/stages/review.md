---
title: 6-review stage
type: stage
source: lib/hive/stages/review.rb, lib/hive/stages/auto_commit.rb, lib/hive/stages/review/{ci_fix,triage,browser_test,fix_guardrail,suppression}.rb, lib/hive/commands/adhoc_review.rb, templates/{fix,ci_fix,browser_test,triage_*}*.erb
created: 2026-04-26
updated: 2026-07-17
tags: [stage, review, autonomous-loop, ci, triage, fix-guardrail]
---

**TLDR**: The autonomous review loop. After 5-open-pr opens a task PR, patrol creates a synthetic `6-review/patrol-.../` task for an opened PR, or `hive review --pr <n>` creates a synthetic `6-review/adhoc-review-pr-<n>/` task for someone else's PR, `Hive::Stages::Review.run!` runs CI on entry, then loops `reviewers → triage → fix` until the branch is clean (or hits a budget cap) and finalises with a browser-test phase. Reviewer and escalation markdown stay authoritative locally and are also mirrored to the GitHub PR as PR-level comments.

## Setup

- **State file**: `task.md` with frontmatter written by 4-execute (`slug`, `started_at`), by patrol handoff (`source: patrol`, finding fingerprint, PR URL), or by ad-hoc PR review (`source: ad-hoc`, PR URL). The runner does NOT track pass count in frontmatter — it derives the current pass by reading `reviews/<reviewer-name>-<NN>.md` filenames and taking the maximum NN.
- **Worktree pointer**: `worktree.yml` (carried over from 4-execute, written by `Hive::Patrol::ReviewHandoff`, or written by `Hive::Commands::AdhocReview`; missing → exit 1 with "6-review entered without a worktree.yml").
- **PR pointer**: `pr.md` (carried over from 5-open-pr or written by patrol/ad-hoc handoff). Missing PR metadata only disables GitHub comment mirroring; local review still runs. Ad-hoc tasks record `pr_number`, `base_ref_name`, `head_ref_oid`, `is_cross_repository`, and `state`.
- **Reviews directory**: `reviews/` (carried over from the normal pipeline or created by patrol/ad-hoc handoff). New per-pass files written here: `<reviewer>-NN.md`, `escalations-NN.md`, `ci-blocked.md` (Phase 1 hard-block), `browser-blocked-NN.md` (Phase 5 warned), `fix-guardrail-NN.md` (post-fix tripped), and `suppressed.md` (operator-visible no-fix suppression list).

## Pre-flight (`Review.run!`)

| Marker / State | Action |
|----------------|--------|
| `:review_complete` | print "already complete; run `hive artifacts` or move this folder to 7-artifacts/", return |
| `:review_ci_stale` | warn; user fixes CI then `hive markers clear FOLDER --name REVIEW_CI_STALE` and re-runs |
| `:review_stale` | warn; user clears/re-runs if highest pass lacks `escalations-NN.md`, otherwise trims `reviews/` then clears/re-runs |
| `:review_error` | terminal review evidence is normalized through `TerminalErrorRegistry` and submitted to the one durable coordinator. Provider/auth, agent death, timeout, integrity, and `unknown` retain different guidance but never different task-stage timing. Status surfaces the exact generation-scoped retry projection. |
| `:review_waiting` | resume — skip Phase 2/3, jump straight to Phase 4 with the user's manually-ticked `[x]` marks |
| no `worktree.yml` | exit 1 (must come from 4-execute) |
| `worktree.yml` points at deleted path | exit 1 with `git worktree prune` recovery hint |

## The pass loop

```
Phase 1 (CI fix)         once on entry
Phase 2 (reviewers)      sequential, one adapter per selected reviewer spec
Phase 3 (triage)         courageous (default) | safetyist | review.triage.custom_prompt
branch on triage:
  any [x]                → Phase 4 (fix) → loop to Phase 2 with pass++
  escalations only       → REVIEW_WAITING escalations=N pass=NN (terminal)
  all clean              → Phase 5 (browser test) → REVIEW_COMPLETE
```

Before spawning the Phase 4 fix agent, `prepare_worktree_for_fix` runs `Hive::Stages::CleanExit` with `reason: :pre_fix_dirty_worktree` when the worktree is already dirty. This pre-fix snapshot auto-commits all residue, not only paths allowed by the normal `review.fix.auto_commit.scope_check` allowlist, because its job is to preserve existing operator/agent changes before handing control to a new fix agent. The stricter scope check still applies to ordinary stage-exit residue and finalize-entry backstops.

Pass cap (`review.max_passes`, default 2) gates re-entry to Phase 2 — exceeding it sets `REVIEW_STALE pass=NN`. Wall-clock cap (`review.max_wall_clock_sec`, default 5400) is checked at every phase boundary and between reviewers inside `run_reviewers`; each reviewer that accepts a `deadline:` kwarg receives the full remaining wall-clock budget, while its own `timeout_sec` remains the per-reviewer cap. Shared Claude tmux readiness waits count against the current reviewer deadline. Exceeding the outer wall-clock cap sets `REVIEW_STALE reason=wall_clock`.

`mark_working(phase:, pass:)` doubles as the event-bracket emitter: each call closes the previously-open phase event (if any) and opens a new `agent_start` with agent label `phase=<name> pass=<NN>`. An `ensure` block at the bottom of `run!` calls `close_phase_event!` so the trailing `agent_end` always lands — return, raise, and `SystemExit` paths all keep the `events.jsonl` brackets balanced. Per-reviewer spawns nest underneath these phase pairs via their own `Hive::Agent#run!` agent_start/agent_end records (agent label `claude review-stub-reviewer-passNN`). See [[modules/events]].

## Phase 1 — CI fix (`Hive::Stages::Review::CiFix`)

Runs `cfg.review.ci.command` (e.g., `bin/ci`) once on entry. The subprocess is launched with `Process.spawn(pgroup: true)` and its combined stdout+stderr is **streamed** through a reader thread with a 256 KB byte-cap applied during read (so a runaway CI cannot OOM the host before the cap kicks in). A per-process timeout from `cfg.timeout_sec.review_ci` (default 3600s) bounds wall time: on expiry the pgid is TERM'd, given a 3s grace, then KILL'd, and the resulting `CommandError` falls through the existing `:error` path. On red exit, the captured log is ANSI-stripped, tail-truncated to the configured line cap, and fed to a fix agent through the per-spawn `<user_supplied>` nonce wrapper. Re-runs CI. Up to `review.ci.max_attempts` (default 3); cap reached → `:stale` → runner writes `reviews/ci-blocked.md` and sets `REVIEW_CI_STALE`. Reviewers do NOT run on red CI.

`review.ci.command` is project-specific by design — hive doesn't ship a Rubocop/Brakeman driver because that would couple the orchestrator to one ecosystem. The user owns the contract; hive shells out and parses exit code + last-N lines.

## Phase 2 — reviewers (`Hive::Reviewers`)

For each selected reviewer spec, sequentially: dispatch via `Hive::Reviewers.dispatch(spec, ctx)`, run the selected adapter, and write `reviews/<output_basename>-<NN>.md`. `kind: "agent"` uses `Hive::Reviewers::Agent` and `Hive::Agent.run!` with the spec's profile; `kind: "codex_review"` uses `Hive::Reviewers::CodexReview`, which runs native `codex review --title <title> <prompt>` and captures valid High/Medium/Nit output into the findings file. The native Codex adapter normalizes stdout before publishing it: after the first severity header, it drops the verbose middle `exec` / `thinking` / `codex` session transcript and keeps codex's final assistant message, so triage reads findings rather than hundreds of KB of tool logs. Normal tasks select specs from `cfg.review.reviewers`; synthetic patrol handoff tasks whose `task.md` frontmatter carries `source: patrol` select specs from `cfg.patrol.review.reviewers` instead, so patrol PRs can use the cheap `codex-native-review` default without changing the normal feature-review policy. Ad-hoc PR tasks whose `task.md` frontmatter carries `source: ad-hoc` select `cfg.review.adhoc.reviewers` when that list is set, otherwise they fall back to `cfg.review.reviewers`. Reviewer prompts compare against `origin/<default_branch>` when that remote-tracking ref exists (probed via the full `refs/remotes/origin/<branch>` path so a like-named tag cannot satisfy the check), falling back to the configured/default local branch only when the remote ref is absent; this keeps long-lived local `main` checkouts from making reviewers report already-merged changes as current-task findings. `hive review --pr` records the PR's declared `baseRefName` in `pr.md`, but v1 still uses the existing default-branch compare path rather than a per-task base override. When `cfg.default_branch` is unset AND `Hive::GitOps#origin_default_branch` returns nil (no origin/HEAD symref and neither `origin/main` nor `origin/master` exist), review preflight refuses to fall back to the worktree's current branch (which in a `git worktree add` is the task branch — diffing the task against itself produces zero or phantom findings) and exits 1 with the two remediation paths named: set `default_branch` in `.hive-state/config.yml`, or run `git remote set-head origin --auto` so origin/HEAD points at the project default.

The patrol selector is deliberately frontmatter-based and fail-soft:
`reviewer_specs_for` reads YAML only when `task.md` starts with a
frontmatter fence, treats malformed or unreadable frontmatter as absent,
and falls back to the normal reviewer list unless `source` stringifies to
`patrol`. The ad-hoc selector uses the same fail-soft reader and only switches
when `source` stringifies case-insensitively to `ad-hoc`.

After each reviewer file is written, `Review::GithubPublisher.publish!` posts a PR-level comment headed `### Reviewer: <name> - Pass NN` when `review.github_publish.enabled` is true. It reads `pr_url` from `pr.md`, skips duplicate headers on retry, scans for secrets before posting, and degrades to a stderr warning on GitHub failures so local files remain the source of truth.

Per-reviewer failures retry up to `max_attempts` (default `Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS = 2`; configurable on each reviewer spec) with exponential backoff capped at 8s (1s, 2s, 4s, 8s, 8s, …). After retries are exhausted, the failure is recorded as a one-line entry in `reviews/errors-NN.md` (an orchestrator-owned file — see `ORCHESTRATOR_OWNED_PREFIXES`); the reviewer's own per-pass output file stays absent so `discover_reviewer_files` correctly reports "this reviewer produced nothing this pass" instead of triaging an infra-failure stub as a real `[ ]` finding. `errors-NN.md` is unconditionally deleted at the start of every `run_reviewers` invocation and re-created on the first failure within that invocation (append-with-header-on-first-write thereafter), so a marker-clear-and-rerun that succeeds leaves no file behind and one that re-fails shows only the latest pass-NN failures rather than concatenated history. All reviewers fail → `REVIEW_ERROR phase=reviewers reason=all_failed` (the all-failed safety net is preserved). Empty reviewer list → skip directly to the all-clean branch (Phase 5).

CE skill invocation is profile-aware: `templates/reviewer_claude_ce_code_review.md.erb` and `templates/reviewer_codex_ce_code_review.md.erb` invoke the same logical CE skill (`/ce-code-review`) but render the call syntax according to `profile.skill_syntax_format`. Legacy config values such as `/compound-engineering:ce-code-review` or `compound-engineering:ce-code-review` are normalized to the current bare CE skill before the prompt is rendered. The official `/code-review` command plugin is a separate PR-comment workflow and is not used here because Hive reviewers must write structured `reviews/<reviewer>-NN.md` artifacts for triage.

Every reviewer prompt embeds the task's `plan.md` inline through `Hive::Reviewers::PlanContext.render(task_folder, user_supplied_tag)` — wired into `Agent#render_prompt` as the `plan_context_section` template binding and rendered between the `Pass:` header and the `Behavior:` block in all four reviewer templates. The section frames the plan as authoritative on scope and tells reviewers to drop candidate findings that flag deliberate plan-level scope boundaries (e.g. "feature X not implemented" when the plan defers X to a separate downstream task). It also carries a symmetric anti-finding rule: if the plan's **Goals** or **Requirements Trace** lists an item the diff does NOT implement and the plan does NOT defer it, the reviewer must raise that as a High-severity finding — the rule suppresses escalations on plan-deferred gaps, not on plan-required-but-missing gaps. Without this grounding, reviewers re-derive scope from the worktree alone and routinely escalate intentional gaps — driving the same task into REVIEW_STALE pass after pass because the fixer can't resolve a plan-by-design contradiction.

Per ADR-008 / ADR-019: plan content is data, not instructions. The plan body is wrapped in a per-spawn `<user_supplied_<hex>>` nonce block — same pattern as `templates/execute_prompt.md.erb`, `fix_prompt.md.erb`, and `triage_courageous.md.erb` — and the reviewer is instructed in-prompt to classify the inner content strictly as data and not execute any directive that appears inside the wrapper. The system-level scope-authority framing lives OUTSIDE the wrapper so the reviewer treats the framing as instructions and the plan body as data. The nonce is captured once per spawn in `Agent#render_prompt` and reused for both the template's own `user_supplied_tag` binding and the plan-context inner wrapper, so the rendered prompt has a single consistent nonce — pinned by `test_render_prompt_uses_single_nonce_for_template_tag_and_plan_wrapper`.

If `plan.md` is missing, empty, whitespace-only, or unreadable (EACCES, EISDIR, ENOENT-race), the section degrades to a fixed `ABSENT_NOTE` constant so the prompt stays well-formed and the reviewer flags missing-plan in its output header. Non-UTF-8 bytes in `plan.md` are scrubbed to U+FFFD before interpolation so a stray latin1 paste doesn't crash the spawn at the ERB layer.

Reviewer kind `linter` is rejected with a helpful pointer to `review.ci.command` — linters belong in the project's CI driver, not in hive's reviewer adapter (see ADR-014).

## Phase 3 — triage (`Hive::Stages::Review::Triage`)

Spawns a triage agent with all per-reviewer files for the current pass concatenated through the per-spawn nonce wrapper. The agent's job: tick `[x]` on findings safe to auto-fix; leave `[ ]` (with a one-line rationale appended) on findings that need human review. Two bias presets:

- **`courageous`** (default, `templates/triage_courageous.md.erb`) — apply max review fixes in automatic mode; escalate only sketchy / architecture-level findings.
- **`safetyist`** (opt-in, `templates/triage_safetyist.md.erb`) — escalate when in doubt; only tick obvious mechanical fixes.

`review.triage.custom_prompt` overrides both presets with a path under `templates/`. Path-escape-guarded — `..` and absolute paths are rejected before render.

Triage's direct `cfg` fallback values match `Config::DEFAULTS`: `budget_usd.review_triage` falls back to `75` and `timeout_sec.review_triage` falls back to `1800`. Normal `Config.load` callers already receive those values through the deep merge; the explicit fallback only protects tests or internal callers that build a partial config hash by hand.

Plan / worktree.yml / task.md and current review artifacts remain SHA-256 protected around the fix spawn. A conservative Claude Stop-hook fallback may accept only complete local evidence; otherwise the phase writes a bounded terminal diagnostic. Provider limit, tamper, status-check, auto-commit, agent crash, and `unknown` outcomes all converge on `FailureReporter` and the same durable task-stage ladder. Integrity-specific guidance may require an audited repair before redispatch, but the review runner does not own a delayed-dispatch timer or marker-clear sequence.

When `review.triage.suppress_no_fix` is not `false` (default on), `Review::Suppression` hardens repeated no-fix findings without changing the all-clean branch. Before triage, it loads `reviews/suppressed.md` and rewrites matching unchecked reviewer lines to `- [x] SUPPRESSED: ...`, so the triage prompt and fix collector ignore findings previously classified as triage `RESOLVED/NO-FIX`. After successful triage, it scans checked `RESOLVED/NO-FIX:` reviewer lines and appends their fingerprints to `suppressed.md`, grouped by severity with High first. The fingerprint key is intentionally loose: severity + normalized file refs (line numbers stripped) + normalized title; justification/body text is excluded. The file is bound to the reviewer compare-base SHA and is hand-editable: uncheck or delete a line to let the finding reach triage again.

The triage phase may make its existing bounded in-attempt subprocess attempts under the review wall-clock budget. Once the durable stage attempt terminalizes, that local phase handling is over: the outcome is reported once to `FailureReporter`, and only the task-stage retry coordinator can schedule or authorize another durable attempt.

If triage exhausts its in-attempt phase-spawn handling, `mark_review_phase_failure` writes the bounded diagnostic marker and terminalization reports it through `FailureReporter`. Provider-limit text is preserved as sanitized `limits_reached` evidence; non-limit output is normalized by `Hive::ReviewErrorReason`, with `unknown` as the fallback and `message=` capped for status. Historical marker `retry_after` attrs are compatibility diagnostics only and never control daemon deadlines. The same terminal reporting boundary applies to fix and CI phase failures.

Escalations land in `reviews/escalations-<NN>.md` — every line that triage left as `[ ]` gets copied here as a digest for the user.

The escalations digest is mirrored to the PR with the same publisher path and duplicate-header guard.

## Branching after triage

- `accepted.empty? && escalations.zero?` with `reviews/errors-NN.md` present — at least one reviewer failed while surviving reviewers found nothing; write `REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=NN` so the task is recoverable/retryable rather than a user-input gate.
- `accepted.empty? && escalations.zero?` without reviewer errors — Phase 2 produced zero findings — jump to Phase 5 (browser test).
- `accepted.empty? && escalations > 0` — Pause for user gate: `REVIEW_WAITING escalations=N pass=NN`. The user ticks `[x]` on whatever escalations they want fixed and re-runs; the runner detects `:review_waiting` resume, skips Phase 2/3, jumps to Phase 4.
- `accepted.any?` — Run Phase 4.

## Phase 4 — fix (`spawn_fix_agent`)

Spawns the fix agent (`cfg.review.fix.agent`, default `claude`) with the concatenated `[x]` lines from every per-reviewer file for the current pass, wrapped in the `<user_supplied>` nonce. Answered escalation body and answer prose is preserved as `[source] >>> ...` context lines so markdown checkboxes inside a user answer cannot inflate `Hive-Fix-Findings`. Ad-hoc PR tasks are review-only by default: if `task.md` has `source: ad-hoc` and `review.adhoc.fix` is not exactly `true`, accepted findings produce `REVIEW_WAITING reason=adhoc_fix_disabled accepted=N pass=NN` so the maintainer can comment on someone else's PR without Hive committing fixes to it. The same fix-off contract also skips Phase 1 CI-fix, so a configured `review.ci.command` cannot spawn a fix agent and auto-commit on a borrowed PR worktree. Set `review.adhoc.fix: true` to opt an ad-hoc task back into the normal fix path; even then the review stage does not push to the remote. The fix prompt requires git trailers on every commit (`Hive-Task-Slug`, `Hive-Fix-Pass`, `Hive-Fix-Findings`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`) — consumed by `hive metrics rollback-rate` (U14). Phase 4 first checks pre-existing worktree dirt: any residue is auto-committed through `CleanExit` with `Hive-Auto-Commit-Reason: pre_fix_dirty_worktree`, the worktree is rechecked, and only a failed status/commit path still prevents the fix agent from running. This pre-fix snapshot intentionally bypasses the shared `review.fix.auto_commit.scope_check` allowlist so out-of-scope residue is preserved before a new fix actor mutates the branch; ordinary stage-exit residue and finalize-entry backstops still use the stricter scope check. If Hive cannot read Git status before or after the fix agent, it records `REVIEW_ERROR phase=fix reason=fix_status_check_failed`; status JSON, bot recovery, and the TUI detail view treat that marker as manual-only because clearing and rerunning would re-enter the same unreadable worktree. If `review.fix.auto_commit.sign_policy: fail` is set and `commit.gpgsign=true`, Hive pauses before staging with `REVIEW_ERROR phase=fix reason=fix_auto_commit_sign_policy_failed`; otherwise, if a successful fix agent starts from a clean snapshot point and exits with uncommitted worktree changes, the runner stages those changes, reads `git diff --cached --name-only -z`, and rejects paths outside `review.fix.auto_commit.scope_check.allowed_paths` or inside `denied_paths` before writing Hive trailers. Scope-check failure unstages and yields `REVIEW_ERROR phase=fix reason=fix_auto_commit_scope_failed`; allowed staged paths are committed with the same trailers before guardrail evaluation, using the worktree's normal signing config by default. `review.fix.auto_commit.sign_policy: bypass` forces unsigned automation commits, and `Hive-Fix-Findings` comes from the accepted-findings collector count rather than reparsing the rendered prompt text. The scope-check / sign-policy / git-commit primitives live in `Hive::Stages::AutoCommit` (a pure module — no instance state) so Review and `CleanExit` share one implementation; `Review::AUTO_COMMIT_*` constants are preserved as aliases for external readers.

The fix prompt (`templates/fix_prompt.md.erb`) tells the agent to **fix the whole defect class, not just the cited line**: when a finding's root cause is an instance of a recurring pattern (e.g. "this path silently swallows a session expiry and seals a partial result as complete"), the agent greps the worktree for the other sites with the *same* defect and applies the identical remedy to all of them in the one pass. This is the single sanctioned exception to the otherwise-strict scoped-edits rule, and it exists to collapse convergence: without it, each reviewer pass re-finds the identical bug at the next site, costing a full extra pass per site (observed on a real xhigh-effort review that found the same silent-truncation class across `walk_timeline`, `get_tweet`, capture, and resync over five passes). It is explicitly not license for unrelated refactors — only to eliminate every instance of the specific defect a finding names.

Plan / worktree.yml / task.md are SHA-256 protected around the fix spawn; tampering → `REVIEW_ERROR phase=fix reason=fix_tampered`. The fix protected set also includes the current pass's escalations/errors/fix-success/fix-guardrail files plus `reviews/suppressed.md`, so a fix agent cannot clear or flip the no-fix suppression list. If the fix agent exits with raw provider-limit `limit_text`, or a legacy AgentLimit wire-format error message, the runner writes `REVIEW_ERROR phase=fix reason=limits_reached retry_after=<iso8601>` through the same `mark_review_phase_failure` helper used by triage. A tmux `claude stop hook did not signal completion` timeout can be suppressed only when `ClaudeLauncher` attached clean turn-end evidence and the review phase can prove all local facts: `reviews/escalations-NN.md` exists and parses, the worktree is readable, the tmux session is still alive (a clean `session_exists? == false` reports `session_alive: false` and stays terminal — gone/unreadable tmux is never suppressed), unresolved escalation count is zero, the error was not a missing-output path, and there is **code-change evidence**. Code-change evidence is one of: a new HEAD since the pass-start baseline; a dirty worktree (the uncommitted fix the orchestrator's post-fix auto-commit will land — HEAD is captured before that commit, so the normal case shows up here); or **whole-pass no-change** — every finding in the pass's reviewer files was dispositioned `RESOLVED/NO-FIX:` with no unapplied `[x] AUTO-FIX:` finding remaining. A single no-fix line in a mixed pass that still owes a real change is NOT proof. Turn-end evidence itself is gated by a work-started latch: `wait_for_done_signal` only trusts an idle pane (or exited process) as "turn ended" after it has first observed the turn underway, so the pre-work idle `❯` prompt that can flash between the Enter keystroke and Claude's first token cannot seal an untouched worktree as complete. `exit_code` in the evidence is advisory-only on the tmux path (always nil); crash protection rests on the code-change + artifacts conjunction, not on an exit code. When that conservative predicate passes, review-fix writes `reviews/fix-success-NN.md` (after the post-fix guardrail, which still owns the sentinel so a guardrail trip withholds it), emits a non-terminal `claude_completion_fallback` event recording the artifact checked and the concrete commit/no-change basis, and continues as a successful fix. All other ordinary non-limit fix-agent errors are classified by `Hive::ReviewErrorReason` from the captured output into `merge_conflict`, `network_timeout`, `tool_permission_denied`, `agent_crashed`, or `unknown` (same input-contract caveat as triage — the launcher forwards a condensed wrapper string, so these usually resolve to `unknown` with the raw cause preserved in `message=`) and remain manual.

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

Only when Phase 2 produced zero findings (`pass=NN-1` was clean). Spawns the configured CE skill (`/ce-test-browser` via `cfg.review.browser_test.agent`) which the agent invokes against the worktree. Returns one of `:passed`, `:warned`, `:skipped`, `:failed`. `:failed` is treated as `:warned` after `review.browser_test.max_attempts` (default 2) — the runner writes `browser-blocked-NN.md` and sets `REVIEW_COMPLETE browser=warned` rather than blocking the loop indefinitely.

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

- **`:complete`** — `reviews/fix-success-NN.md` sentinel exists AND its mtime is ≥ `escalations-NN.md`'s mtime, OR pass `N+1` reviewer files exist. `next_pass_for` advances to `N+1`.
- **`:triage_incomplete`** — reviewer files for pass N exist but `escalations-NN.md` is missing. `next_pass_for` returns N; the loop re-runs Phase 2/3 to re-derive escalations.
- **`:fix_incomplete`** — reviewer files AND `escalations-NN.md` exist, AND one of: (a) neither the sentinel nor pass `N+1` reviewer files exist (fix never finished), OR (b) the sentinel exists but the operator edited `escalations-NN.md` strictly after the sentinel was written (`escalations.mtime > fix-success.mtime`). `next_pass_for` returns N; the loop **skips Phase 2/3** on the first iteration and runs Phase 4 directly on the operator's current `[x]` marks (mirrors a `REVIEW_WAITING` resume).

The operator-edit detection keeps a repaired pass's current `[x]` marks
authoritative. Enter opens the focal escalation file; after editing, the
operator uses the generation-guarded retry action instead of clearing a marker
and starting an unfenced stage process.

The `reviews/fix-success-NN.md` sentinel remains protected orchestrator state.

Recovery flow:

1. Inspect and fix the current review artifacts. Preserved files let a fenced
   successor resume incomplete triage or fix work.
2. `hive retry manual TARGET --generation N` may wake only an already-due
   record and never bypasses cooldown.
3. After repair, run `hive retry repair TARGET --generation N --actor WHO
   --reason WHY`; this audited reset makes the record ready for normal
   capacity-gated durable dispatch.
4. Genuine max-pass, CI, integrity, and unknown failures retain their specific
   diagnostic guidance but use the same coordinator ladder.

No frontmatter edits are required: pass count is filename-derived, and
preserved artifacts are not retry reset signals.

## Tests

- `test/integration/run_review_test.rb` — pre-flight short-circuits, missing-worktree handling, clean fast path, CI hard-block, wall-clock cap including triage-retry handoff to `REVIEW_STALE`, reviewers all-limit markers, triage/fix limit vs non-limit failure classification, transient triage retry, ad-hoc fix-off/fix-opt-in branching, tmux Stop-hook fix fallback acceptance for commit and whole-pass no-change evidence, rejection when commit/no-change evidence or escalation clearance is missing, and `message=` surfacing on terminal phase-agent errors.
- `test/unit/stages/review/{ci_fix,triage,browser_test,fix_guardrail,suppression}_test.rb` — phase-level unit coverage, including no-fix fingerprint normalization, base-SHA reset, strip, and seed behavior.
- `test/unit/stages/review/run_reviewers_test.rb` — reviewer selection, per-reviewer failure handling, shared Claude tmux reviewer sessions, wall-clock deadlines, GitHub mirroring, patrol-task selection of `patrol.review.reviewers`, and ad-hoc reviewer selection/fix-gate helpers.
- `test/unit/reviewers_test.rb`, `test/unit/reviewers/agent_test.rb`, `test/unit/reviewers/codex_review_test.rb` — adapter dispatch, agent-kind reviewer, and native Codex-review adapter behavior including transcript trimming before triage.
- `test/unit/metrics_test.rb`, `test/integration/metrics_command_test.rb` — `hive metrics rollback-rate` against trailered fixture commits.

## Backlinks

- [[stages/open-pr]] · [[stages/finalize]]
- [[modules/patrol]]
- [[modules/markers]] · [[modules/agent]] · [[modules/config]]
- [[state-model]] · [[decisions]] · [[architecture]]
