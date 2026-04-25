# Wiki Changelog

Append-only log of all wiki operations.

## [2026-04-25T18:00:00Z] brainstorm: 5-review stage

**Action:** Captured requirements for splitting 4-execute into impl-only + a new 5-review stage that runs CI-fix → multi-reviewer (parallel) → auto-triage → fix → browser-test as a fully autonomous loop. Renumbers pr/done.

**Key decisions:**
- Split execute → execute (impl) + 5-review (loop). Renumber 5-pr → 6-pr, 6-done → 7-done.
- Fully autonomous run; user only enters at REVIEW_WAITING (escalations) or REVIEW_COMPLETE.
- Auto-triage with `liberal_auto_fix` preset (configurable: conservative / aggressive / custom prompt path).
- CI hard-blocks on cap; browser-test soft-warns.
- Multi-reviewer parallel: claude-ce-review, codex-ce-review, pr-review-toolkit, optional linters-as-reviewers.
- Triage edits per-reviewer files in place + writes consolidated `escalations-NN.md`.
- Workflow primitives stay CE skills (portable across Claude Code / Codex CLI / etc.).

**Doc:** `docs/brainstorms/hive-review-stage-requirements.md`.

**Supersedes:** F2 + R6/R7/R8 in `docs/brainstorms/hive-pipeline-requirements.md` (the original review-iteration requirements inside 4-execute).

**Wiki pages updated:** — (none yet; follow-up after `/ce-plan` and implementation will refresh `stages/execute.md`, add `stages/review.md`, update `stages/index.md`, `state-model.md`, `modules/config.md`, `decisions.md`.)

## [2026-04-25T00:00:00Z] bootstrap

**Action:** Initial wiki bootstrap from codebase (per `~/wikis/bootstrap-wiki.md` plan via gist `f53222b0d3ace9086be820d366b621e4`).

**Pages created:**
- Top level: `architecture.md`, `state-model.md`, `cli.md`, `dependencies.md`, `decisions.md`, `active-areas.md`, `gaps.md`, `templates.md`, `testing.md`, `index.md`, `log.md`.
- Commands: `commands/init.md`, `commands/new.md`, `commands/run.md`, `commands/status.md`.
- Stages: `stages/index.md`, `stages/inbox.md`, `stages/brainstorm.md`, `stages/plan.md`, `stages/execute.md`, `stages/pr.md`, `stages/done.md`.
- Modules: `modules/task.md`, `modules/markers.md`, `modules/lock.md`, `modules/worktree.md`, `modules/git_ops.md`, `modules/agent.md`, `modules/config.md`.

**Pages updated:** —

**Gaps found:**
1. No live `claude` v2.1.118 smoke-test recorded.
2. `hive init` not yet exercised against the pilot project.
3. `git config gc.reflogExpire never refs/heads/hive/state` not enforced in `Init#call`.
4. Pilot project's pre-commit hook interaction with `.hive-state/` commits unverified.
5. macOS PID-reuse fallback for stale-lock detection not implemented.

**Source:** Codebase read (`lib/`, `bin/`, `templates/`, `test/`) + author's local planning notes. No git history available — repository had no commits yet at the time of bootstrap.

## [2026-04-25T11:50:00Z] post-MVP-review hardening

**Driver:** /ce-code-review on the Phase 1 MVP commit surfaced 1 P0, 9 P1, ~20 P2/P3 findings plus wiki drift. This entry records the code/security/reliability changes; wiki pages were synced in the same change.

**Code changes (all behind passing tests; no regressions in 91-test suite):**

- **P0 worktree.yml hijack closed** (`lib/hive/stages/execute.rb`): `worktree_root` is now derived canonically from `cfg["worktree_root"] || ~/Dev/<project>.worktrees` instead of `File.dirname(worktree_path)`. The fallback was tautological — agent-rewritten pointer paths were validating against their own dirname. Plus: implementation pass is now wrapped in the same SHA-256 protection as the reviewer pass — both runs verify `plan.md` and `worktree.yml` haven't been mutated, with `:error reason=implementer_tampered` / `reviewer_tampered`.
- **Symlink escape closed** (`lib/hive/worktree.rb`): `validate_pointer_path` uses `File.realpath` so symlinks can't shadow the prefix check.
- **Prompt-injection nonce wrapper** (`lib/hive/stages/base.rb`, all 4 templates): `Stages::Base.user_supplied_tag` returns `user_supplied_<hex16>` rotated per process. Templates wrap user content with the nonce-tag so attacker `</user_supplied>` payloads cannot terminate the wrapper. Plan U11's mandated regression test is now in `test/integration/prompt_injection_test.rb`.
- **Brainstorm/plan add-dir narrowed** (`lib/hive/stages/{brainstorm,plan}.rb`): dropped `add_dirs: [task.project_root]`. Early-stage agents no longer have project-source write access via `--dangerously-skip-permissions`. Trade-off: the agent loses CLAUDE.md auto-discovery at brainstorm/plan; we accept that until a snapshot-mount approach is designed.
- **Pass counter from reviews/** (`lib/hive/stages/execute.rb`): `current_pass_from_reviews` counts `Dir[reviews/ce-review-*.md]` instead of parsing task.md frontmatter. Removes the agent-must-update-frontmatter contract that was contradicting the reviewer prompt's "do not edit task.md" rule.
- **Reviewer prompt rewritten** (`templates/review_prompt.md.erb`): step 4 was "do not edit task.md" while step 5 said "update pass: in task.md frontmatter". Reviewer now writes only the review file; the orchestrator's `finalize_review_state` owns the terminal marker.
- **Atomic Markers.set** (`lib/hive/markers.rb`): tempfile + `File.rename` instead of truncate+write. ENOSPC/crash mid-write no longer corrupts state. UTF-8 encoding pinned. Lock moved to a `.markers-lock` sidecar so reads of the data file don't see partial writes.
- **PR secret-scan** (`lib/hive/stages/pr.rb`): regex scan on `pr.md` + `gh pr view --json body` for api-key/AWS/GH-token/PEM patterns. Hit → marker `:error reason=secret_in_pr_body`, no commit. Implements the lint promised in plan KTD that was missed at MVP time.
- **Reliability batch** (`lib/hive/agent.rb`, `lib/hive/lock.rb`): reader thread sets `report_on_exception = true`; `Process.wait2` for atomic status capture (no `$?` race); `with_commit_lock` has a 30s deadline (`flock LOCK_NB` + sleep poll); `update_task_lock` writes via tempfile + rename; `process_start_time` falls back to `ps -o lstart=` on macOS; nil exit_code + `:none` marker now produces `:error reason=no_marker_no_exit_code` instead of silent OK.
- **Network timeouts** (`lib/hive/stages/pr.rb`): `gh auth status`, `git push -u origin`, and `gh pr list` all wrapped in `Timeout.timeout(60)` so a network drop can't hang the pipeline. `gh pr list` now queries `--state all` instead of `--state open` so a closed-then-retried PR doesn't create a duplicate.
- **hive_state_init pre-flight** (`lib/hive/git_ops.rb`): refuses init on a repo with zero commits (`git rev-parse --verify HEAD`) instead of failing mid-bootstrap.
- **hive_commit scope narrowed** (`lib/hive/git_ops.rb`): adds only `stages/<stage>/<slug>` + `logs/`, not the whole tree, so a crashed prior run's leftover staging cannot cross-contaminate.
- **Slug hygiene** (`lib/hive/commands/new.rb`): derived prefix capped at 51 chars so SLUG_RE always passes; reserved list grew to include `hive-state`/`hive_state`/`state` (worktree-vs-orphan-branch confusion); error message no longer mentions a non-existent `--slug` flag.
- **Status pid lookup** (`lib/hive/commands/status.rb`): reads `claude_pid` from the per-task `.lock` file (where `Hive::Agent` actually writes it) instead of marker attrs (where it never appears).

**Pages updated:**
- `wiki/modules/agent.md` — removed inode-tracking sections; documented `--verbose` requirement; updated `handle_exit` table for the nil-exit_code/`:none` case.
- `wiki/architecture.md` — security-boundary list rewritten (nonce wrapper, narrowed add-dir, two-pass SHA-256, PR secret-scan); `build_cmd` block adds `--verbose`; agent-loop step 6 no longer mentions inode comparison.
- `wiki/decisions.md` — ADR-008 amended with the post-MVP boundary set.
- `wiki/index.md`, `wiki/gaps.md` — line edits removing inode language.

**Tests added:**
- `test/integration/prompt_injection_test.rb` — 5 cases asserting nonce wrapping per template + per-process tag rotation; covers the plan U11 regression mandate.

**Tests:** 91 / 290 assertions, all green.

## [2026-04-25T14:50:00Z] CLI: --json + hive approve

**Driver:** Agent-callable contract work. `hive run` and `hive status` gained `--json` (commits 85439ee, predecessors); `hive approve TARGET` was added (32b0e8c) as the agent replacement for shell `mv <task> <next-stage>/`. Stable exit codes formalised in `Hive::ExitCodes`; schema versions pinned in `Hive::Schemas::SCHEMA_VERSIONS`.

**Code changes:**
- `lib/hive.rb` — `Hive::ExitCodes` constants (0/1/2/3/4/64/70/75/78); `Hive::Schemas::SCHEMA_VERSIONS` (`hive-status`, `hive-run`, `hive-approve` all v1) and closed `NextActionKind` enum. New typed exceptions `TaskInErrorState` (exit 3), `WrongStage` (exit 4), `AlreadyInitialized` (exit 2); existing exceptions now override `exit_code` to match the contract.
- `lib/hive/cli.rb` — `--json` is a `class_option` honoured by `status` and `run`; new `approve` subcommand with `--to`, `--project`, `--force`, `--json`.
- `lib/hive/commands/approve.rb` (new) — slug-or-folder resolution across registered projects, lowest-stage-wins disambiguation within a project, marker policy (forward auto needs `:complete`/`:execute_complete`, `--to` and `--force` bypass), `FileUtils.mv` + `git add -A` on both source and destination parent stage dirs, single hive/state commit per move.
- `lib/hive/commands/{run,status}.rb` — `--json` emit paths producing `hive-run` / `hive-status` documents.
- `lib/hive/commands/init.rb` — `warn`/`exit 2` replaced with `raise Hive::AlreadyInitialized`.
- `lib/hive/stages/inbox.rb` — inert `1-inbox` now `raise Hive::WrongStage` (exit 4) instead of warn/exit, so agent callers can branch without parsing stderr.

**Pages updated:**
- `wiki/cli.md` — command table grew `approve`; `--json` noted as `class_option`; full exit-code contract table.
- `wiki/commands/approve.md` (new) — usage, slug resolution rules, marker policy, JSON contract, exit codes.
- `wiki/commands/run.md`, `wiki/commands/status.md` — `--json` output shape and schema pin.
- `wiki/stages/inbox.md` — `WrongStage` raise + exit 4 documented.
- `wiki/active-areas.md`, `wiki/stages/execute.md` — refreshed (a2b9e05).
- `wiki/dependencies.md` — new dev gems (rubocop-rails-omakase, brakeman, bundler-audit; 7373114).
- `wiki/index.md` — `commands/approve` added; `--json` notes on `run` / `status`.

**Tests:** 11 new integration cases for `approve` (happy path, inbox needs `--force`, backward `--to`, short stage names, unknown stage, slug not found, cross-project ambiguity, destination collision, folder-path target, JSON schema, 6-done overflow). Suite: 115 / 417 assertions, all green. RuboCop clean.

## [2026-04-25T18:00:00Z] hive approve hardening — full ce-code-review remediation

**Driver:** /compound-engineering:ce-code-review against PR #4 (`feat/hive-approve`) ran 8 reviewer personas in parallel and surfaced ~50 findings, including 5 P1s. Two P1s (JSON-on-error silence; non-idempotent retry) were independently called out by three separate reviewers. This entry records the remediation; merge of PR #4 is gated on it.

**Cross-project context:** No prior pattern in `~/wikis/master/wiki/` for "agent-callable equivalents of shell verbs"; this is the first such command in the project, so its conventions (typed exceptions per failure mode, slug-scoped commits, JSON error envelope mirroring stdout/stderr dual-signal of `hive run --json`, idempotency via `--from STAGE`) set the precedent for future agent-callable subcommands.

**Code changes:**

- **JSON error envelope on every failure path** (`lib/hive/commands/approve.rb`): every `Hive::Error` raised inside `do_call` is caught, emitted as a `{schema, schema_version, ok: false, error_class, error_kind, exit_code, message, ...}` document on stdout (with structured fields per error class — `candidates` for `AmbiguousSlug`, `path` for `DestinationCollision`, `stage` for `FinalStageReached`), then re-raised so `bin/hive` produces the contract exit code. Mirrors `hive run --json`'s dual-signal pattern (run.rb:91-95).
- **`--from STAGE` idempotency assertion**: Thor option + `validate_from!` enforces "task is at expected stage" before advancing. Mismatch → `WrongStage` (exit 4). Closes the live-reproducible bug where `hive approve <slug> --force --json` twice in a row silently advanced two stages.
- **Slug-scoped git add** (`record_hive_commit`): `git add -A stages/<src>/<slug> stages/<dst>/<slug>` instead of `stages/<src> stages/<dst>` (parent dirs). Sibling-task changes no longer get swept into the approve commit message. Source side is added only if it has tracked files (`git ls-files` check) — `git add -A <pathspec>` errors on a missing-from-worktree pathspec with no tracked entries, the common case for an untracked source after a prior raw `mv`.
- **Atomic move + commit with rollback** (`perform_move_and_commit`, `record_commit_or_rollback!`): outermost `with_commit_lock(hive_state_path)` surfaces lock contention BEFORE any filesystem mutation; inner `with_task_lock(task.folder)` blocks concurrent `hive run` on the same task during the move; the orphan `.lock` file at the destination (carried by the move) is deleted before the commit so per-process metadata isn't tracked. If the commit fails, `FileUtils.mv` reverses the move and the original error is wrapped in `Hive::Error` so fs and git don't diverge.
- **Same-project multi-stage ambiguity raises** (`find_slug_across_projects` rewrite): silently picking the lowest stage was wrong for the partial-failure-recovery case where the lower stage is the stale leftover. Now raises `AmbiguousSlug` with structured `candidates` and demands an absolute folder path or `--to` to disambiguate.
- **Absolute-path TARGET + `--project` mismatch refused** (`validate_project_path_match!`): combining `--project foo` with `/path/to/bar/.hive-state/...` no longer silently operates on `bar`.
- **`--to <current-stage>` is a clean no-op**: emits `noop: true` in JSON (or `hive: noop —` text), no mv, no commit, exit 0. Previously triggered the destination-collision error.
- **Cwd collision shadow fixed**: bare slug always goes through cross-project search (`path_target?` requires `/` or `~`/`.`). Previously a `pwd` subdirectory matching the slug name took precedence and produced a confusing `InvalidTaskPath`.
- **`Hive::FinalStageReached` exit 4** instead of bare `Error` exit 1 for past-`6-done`. Pairs with the existing collision-stays-at-1 to give callers distinct codes for "no further stage" vs "recoverable collision".
- **`Hive::Stages` module** (`lib/hive/stages.rb`, new): single source of truth for stage list. `GitOps::STAGE_DIRS`, `Status::STAGE_ORDER`, `Run#next_stage_dir`, `Approve` resolution all delegate. Adding a 7th stage is a one-file change.
- **Thor `enum:` constraint** on `--to` / `--from`: invalid stage values fail at parse time with the valid set listed in `hive help approve`.
- **`bin/hive` `--help` flag interception**: `hive <cmd> --help` now works (Thor only honours `--help` before the subcommand name; `<cmd> --help` was being consumed as the next positional). 4-line rewrite in `bin/hive` benefits every subcommand.
- **`hive-approve` schema split**: `from_stage` (bare "brainstorm") + `from_stage_index` (2) + `from_stage_dir` ("2-brainstorm"), mirroring `hive-run`'s `stage` / `stage_index`. Added `ok`, `noop`, `direction`, `forced`, `from_marker`, `next_action` fields. Schema version stays at 1 (no consumers in the wild).
- **`NextActionKind::RUN`** added to the closed enum so `approve --json`'s `next_action.kind` can chain deterministically to `hive run`. Membership pinned in `test/unit/exit_codes_test.rb#test_next_action_kind_closed_enum_membership`.

**Pages updated:**
- `wiki/commands/approve.md` — full rewrite: new flags (`--from`), expanded JSON contract (success + error envelope), updated marker policy, locking-and-rollback section, slug resolution rules including same-project ambiguity, expanded exit-code table.
- `wiki/cli.md` — "five commands"; `--json` honoured by `status`, `run`, AND `approve`; `--help` interception note; expanded approve row in command table.
- `wiki/commands/run.md`, `wiki/commands/status.md`, `wiki/stages/index.md` — added `[[commands/approve]]` reciprocal backlinks.

**Tests:** 20 new integration cases (`run_approve_test.rb`) + 4 new unit assertions (`exit_codes_test.rb`) — coverage for: `--from` idempotency mismatch, all six short stage names, project-filter zero matches, cwd-shadow defence, `:error` marker forward refusal AND backward `--to` recovery, past-6-done exits 4, no-op same-stage in both text and JSON, JSON full key-set pin including new fields, JSON error envelopes for each typed error class (ambiguous, collision, final-stage), no-op next_action at final destination, slug-scoped commit (cross-contamination prevention), orphan `.lock` cleanup, plain-text stderr-hint placement, absolute-path + project mismatch, same-project multi-stage ambiguity. Suite: 135 / 507 assertions, all green.

**Findings dismissed (false positives):**
- `wiki commit_action` doc-vs-code mismatch (project-standards reviewer): verified `Hive::Task#stage_name` returns the bare suffix, so `"#{stage_index}-#{stage_name}"` correctly emits `"2-brainstorm"`. Doc and code agree.

**Findings deferred (P3, separate PRs):**
- Symlink TARGET hardening (adversarial #6) — `File.symlink?` defence at task construction.
- TOCTOU on destination check (adversarial #8) — covered indirectly by `with_task_lock` but not eliminated.
- Published JSON Schema files (api-contract #4) — `schemas/hive-approve.v1.json` for external consumers.
- Pre-existing `.lock` files committed by `hive run` — would need `.gitignore` inside `.hive-state/`.
