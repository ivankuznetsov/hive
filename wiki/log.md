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

## [2026-04-25T20:00:00Z] hive approve P3 follow-up — symlink, TOCTOU, schemas, .gitignore

**Driver:** Continuation of the ce-code-review PR #4 remediation: addressing the four P3 items deferred from the prior commit. All four turned out to be sub-day fixes; bundling them into the same PR keeps the work coherent.

**Code changes:**

- **Symlink hardening** (`lib/hive/commands/approve.rb`): `resolve_target` now `File.realpath`s the resolved folder for both the path-target and slug-search return paths. A slug-named symlink at `.hive-state/stages/<N>/<slug>` pointing to `/tmp/leaked` realpaths to `/tmp/leaked` and gets refused by `Hive::Task.new`'s PATH_RE check (real path doesn't match the `.hive-state/stages/` shape). Two integration tests pin both the path-target and slug-lookup branches.
- **TOCTOU robustness** (`move_task!`): switched from `FileUtils.mv` to direct `File.rename` wrapped in a `rescue Errno::ENOTEMPTY, EEXIST, EISDIR` that surfaces as typed `Hive::DestinationCollision`. The pre-check + commit-lock cover the hive-process-vs-hive-process race; the rescue covers the non-hive-process race (a stray `mkdir` between pre-check and rename). Cross-device fallback (rare; `.hive-state` lives under the project root) goes through `cp_r` + `rm_rf`. One integration test stubs `File.exist?` to bypass the pre-check and asserts the rescue produces a clean `DestinationCollision`.
- **NextActionKind::APPROVE** (`lib/hive.rb`, `lib/hive/commands/run.rb`): added to the closed enum (additive). `hive run --json` now emits `kind: "approve"` for `:complete` and `:execute_complete` markers (was `kind: "mv"`), with a new `command: "hive approve <slug> --from <stage>"` field that the agent can copy-paste-execute. Back-compat `from` / `to` fields are kept on the next_action object so old callers parsing the MV shape still get the data they need. `MV` stays in the closed enum per the additive-only policy. Test `test_run_json_on_complete_marker_returns_approve_next_action` (renamed from `_returns_mv_next_action`) pins the new shape; the closed-enum membership test covers both kinds.
- **Published JSON Schema** (`schemas/hive-approve.v1.json`): draft 2020-12 schema with `oneOf` over `SuccessPayload` and `ErrorPayload` definitions, per-stage enums, and the closed `NextAction.kind` enum. `Hive::Schemas.schema_dir` and `Hive::Schemas.schema_path(name)` helpers resolve the absolute path. `test/unit/schema_files_test.rb` pins the schema's required-key set, error_kind enum, and NextAction.kind enum against the producer's emission so a code-vs-schema drift fails at test time. External consumers (non-Ruby SDKs, CI validators) can validate emitted documents with any draft-2020-12 validator (ajv, json_schemer, etc.) without re-implementing the contract.
- **`.hive-state/.gitignore`** (`lib/hive/git_ops.rb`): `hive_state_init` now bootstraps a gitignore at the `.hive-state` root excluding per-task `.lock`, atomic-write `.lock.tmp.*`, per-marker `*.markers-lock`, and per-project `.commit-lock`. Pre-existing pre-bug: `Hive::GitOps#hive_commit` does `git add stages/<stage>/<slug>` which was tracking the per-task `.lock` files into hive/state on every `hive run` (committed PIDs and process_start_time values). Existing projects need to add the `.gitignore` manually; new projects get it via `init`.

**Tests:** 7 new integration / unit cases covering symlink-target rejection (path-target + slug-lookup), concurrent-mkdir collision rescue, schema file existence and key-set drift, schema error_kind drift, schema NextAction.kind drift. `test_run_json_on_complete_marker_returns_approve_next_action` renamed and rewritten. Suite: 142 / 529 assertions, all green. RuboCop clean.

**Wiki updates:**
- `wiki/commands/approve.md` — symlink hardening note in Steps section, TOCTOU rescue noted, JSON Schema file referenced under JSON contract.
- `wiki/cli.md` — `Hive::Schemas.schema_path("hive-approve")` mentioned for external consumers.

## [2026-04-25T22:00:00Z] hive approve round-3 review remediation

**Driver:** /pr-review-toolkit:review-pr final pass surfaced silent-failure (6), type-design (5), test-coverage (6), comment-rot (8), and project-standards (3) findings. All addressed in this commit.

**Code changes:**

- **JSON envelope on non-`Hive::Error` failures** (`approve.rb` `call`): added a second `rescue StandardError` that wraps in new `Hive::InternalError` (exit 70 / SOFTWARE) and emits the JSON envelope. An Errno::ENOSPC from `mkdir_p`, an Open3 fault, or a SystemCallError no longer escapes as a Ruby trace on stderr while a `--json` consumer reads EOF on stdout.
- **`record_commit_or_rollback!` rescue narrowed** from `StandardError` to `Hive::Error, SystemCallError`. The broad rescue was swallowing typed errors and rewrapping them as exit 1; typed errors (`Hive::GitError` exit 70) now re-raise unchanged after rollback.
- **`attempt_rollback!` extracted** with its own inner rescue around the rollback `FileUtils.mv`. If the rollback itself fails, original cause AND rollback failure both surface in one message.
- **`cross_device_move!` extracted** with cleanup on partial `cp_r` failure. ENOSPC mid-tree no longer leaves a half-copy + intact source.
- **`cleanup_orphan_task_lock` rescue narrowed** to `Errno::ENOENT` only. Other I/O errors propagate so rollback runs.
- **`source_has_tracked_files?` checks status**. A failed `git ls-files` was silently being read as "no tracked files," skipping the source-side add. Now raises `Hive::GitError`.
- **`Hive::Stages.parse` validates `DIRS.include?(dir)` first**. `parse("99-foo")` returns nil, not `[99, "foo"]`.
- **`Hive::Stages.next_dir` raises on out-of-range / non-integer**. Off-by-ones surface at the call site.
- **`GitOps::STAGE_DIRS` and `Status::STAGE_ORDER` aliases removed**. Both consumers reference `Hive::Stages::DIRS` directly. Closes the half-migration smell.
- **CLAUDE.md-violating comments fixed**: removed "now treated as", "silently picking the lowest stage was wrong for the partial-failure-recovery case", "Raised by `hive approve`", "APPROVE replaces the old MV emission" and similar transitional / caller-tying / contrast-with-old-behavior phrasings that rot. The structural WHY in each location was preserved or restated as a positive.
- **POSIX rename overclaim corrected** (`move_task!` comment): "silently REPLACE … POSIX rename(2) semantics" was libc-dependent, not portable; reworded to "implementations vary; the rescue covers all three errnos."
- **`--to disambiguates same-project ambiguity`** docstring claim corrected (it doesn't — `--to` selects destination, not source). Same fix in `wiki/commands/approve.md`.

**Wiki updates:**

- `wiki/modules/stages.md` (new) — module page per project convention. Covers DIRS / NAMES / SHORT_TO_FULL constants, `next_dir` / `resolve` / `parse` helpers, the consumer table, and the rationale for module-vs-class.
- `wiki/index.md` — adds `[[modules/stages]]` to the Modules list.
- `wiki/state-model.md` — points the canonical-stage-list claim at `Hive::Stages::DIRS` (was `Hive::GitOps::STAGE_DIRS`).
- `wiki/modules/git_ops.md` — removed the `STAGE_DIRS` constant entry; documents `HIVE_STATE_GITIGNORE` and points to [[modules/stages]] for the stage list.
- `wiki/commands/status.md` — `Hive::Stages::DIRS` reference instead of the deleted `STAGE_ORDER`.
- `wiki/commands/approve.md` — corrected `--to disambiguates` claim.

**Tests:** 7 new (149 / 576 green), RuboCop clean.

- `test/unit/stages_test.rb` (new) — validation semantics for `next_dir` (raises on bad index), `parse` (nil for unknown stages), `resolve`, and constant frozen-ness.

## [2026-04-25T23:00:00Z] hive findings / accept-finding / reject-finding (Phase 2 PR3)

**Driver:** Continuation of Phase 2 agent-callable contract work. `hive approve` (PR #4, merged) replaced shell `mv`; this commit replaces the second hand-edit step in the pipeline — ticking `[x]` on review findings in `reviews/ce-review-NN.md` to mark which findings the next implementation pass should address. The reviewer prompt writes all findings unchecked; the user (now an agent) flips a subset to accepted; `Hive::Stages::Execute#collect_accepted_findings` re-injects only the `[x]` lines into the next pass's prompt.

**Code changes:**

- **`Hive::Findings`** module (`lib/hive/findings.rb`, new) — parser + writer for review files. `Document.new(path)` reads the file, parses each `- [ ]` / `- [x]` line into a `Data.define` value object with `id` (1-based stable; document order), `severity` (lowercased heading), `accepted`, `title`, `justification`, `line_index`. `toggle!(id, accepted:)` flips a single checkbox character without touching surrounding bytes — verified by a unit test that asserts every non-target line is byte-identical after a write. `write!` uses tempfile + rename. `summary` returns total / accepted / by_severity. `Hive::Findings.review_path_for(task, pass:)` resolves the latest or named-pass review file.
- **`Hive::TaskResolver`** (`lib/hive/task_resolver.rb`, new) — extracted from `Hive::Commands::Approve#resolve_target` + `find_slug_across_projects` + `validate_project_path_match!`. ~80 LOC of slug-or-folder resolution now shared between four commands (`approve`, `findings`, `accept-finding`, `reject-finding`); `Approve#do_call` is one line shorter and the duplication that would have appeared in three new commands is collapsed at extraction time.
- **`Hive::Commands::Findings`** (`lib/hive/commands/findings.rb`, new) — read-only list. Resolves task via `TaskResolver`; loads document; emits text table or single-line `hive-findings` JSON. JSON includes per-finding `to_h` plus `summary` block.
- **`Hive::Commands::FindingToggle`** (`lib/hive/commands/finding_toggle.rb`, new) — shared accept/reject. Combines `ID...` positionals + `--severity <s>` + `--all` into a unioned ID list (empty union is an error). Validates every ID exists; flips checkboxes; atomic write; commits to `hive/state` (slug-scoped `git add` of the review file). Acquires `Hive::Lock.with_task_lock(task.folder)` so a concurrent `hive run` can't race against the toggle. Idempotent: already-correct entries are no-ops and excluded from the JSON `changes` array. `next_action` in the JSON points at `hive run <task.folder>` so an agent driving the pipeline knows the immediate next step.
- **CLI wiring** (`lib/hive/cli.rb`): three new Thor subcommands. `--severity` Thor `enum:` constraint against `%w[high medium low nit]`; `--pass` numeric; `--all` boolean; positional `IDs` is variadic (`*ids`).
- **Typed exceptions** (`lib/hive.rb`): `Hive::NoReviewFile` (exit 64), `Hive::UnknownFinding` (exit 64, carries `id`).
- **`Hive::Schemas::SCHEMA_VERSIONS["hive-findings"] = 1`** added.
- **`schemas/hive-findings.v1.json`** — draft 2020-12 schema with `oneOf` over `ListPayload`, `TogglePayload`, and `ErrorPayload`. Per-finding shape, summary, error-kind enum (`ambiguous_slug`, `no_review_file`, `unknown_finding`, `invalid_task_path`, `error`), and the closed `NextAction.kind` enum.

**Wiki updates:**

- `wiki/commands/findings.md` (new) — full page for the three commands. Data model, JSON contract for both list and toggle paths, error envelope, exit-code table, locking section, "why not just edit the file" rationale, backlinks.
- `wiki/cli.md` — TLDR updated to "eight commands"; command table grew three rows; `--json` honour list extended.
- `wiki/index.md` — new entry under Commands; page count bumped 27 → 29.
- `README.md` — daily-usage table grew three rows.

**Tests:** 27 new (176 / 699 green; was 149 / 576 on round-3-merged main). RuboCop clean.

- `test/unit/findings_test.rb` — 9 cases on the parser: severity/order/state pinning, missing-justification handling, summary counts, byte-for-byte round-trip preservation, idempotent toggle, unknown-id raises typed, missing-file raises typed, latest-pass resolution, named-pass missing.
- `test/integration/run_findings_test.rb` — 13 cases on the three commands: text output shape, full JSON-key-set pin, named-pass selection, no-review-file error envelope, accept by ID, accept --severity, accept --all (with no-op detection on already-accepted entries), idempotent re-accept, unknown-id typed error, no-selectors error, reject behaviour, reject idempotency, task-lock contention surfaces ConcurrentRunError (TEMPFAIL/75).
- `test/unit/schema_files_test.rb` — 4 new pins for hive-findings: file existence + draft, ListPayload required keys, TogglePayload required keys, error_kind enum drift.
- `test/unit/exit_codes_test.rb` — pinned `NoReviewFile` (64), `UnknownFinding` (64), `InternalError` (70) exit codes; pinned `hive-findings` schema-versions key.

**Refactor:**

- `Hive::Commands::Approve` was simplified to delegate to `Hive::TaskResolver`. ~80 LOC removed from `approve.rb`; one line in `do_call` (`task = Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve`). All 32 existing approve tests still pass.

## [2026-04-25T23:30:00Z] hive findings — round-2 ce-code-review remediation

**Driver:** /compound-engineering:ce-code-review on PR #5 ran 8 reviewer personas (cli-readiness ran out of tokens; the other 8 produced findings). 4 P1s + 8 P2s + a few P3s addressed in this commit. Two of the P1s were independently corroborated by 2 reviewers each.

**Code changes:**

- **Lock-order inversion fixed** (`finding_toggle.rb#do_call`): swapped to `with_commit_lock` outermost → `with_task_lock` inner, matching `Hive::Commands::Approve`. Closes the deadlock where concurrent `hive approve <slug>` + `hive accept-finding <slug>` would both wait 30s on each other's lock and surface as `ConcurrentRunError`.
- **Rollback false-failure message fixed** (`rollback_review_change!`): the previous shape used a method-level rescue that caught the intentional "rolled back" re-raise on the success path and falsely reported "rollback ALSO failed." Restructured to a flat `begin/rescue` where the rollback I/O is the rescued region; the success-path re-raise leaves the method without re-entering any rescue. The "rollback failed" branch is now reserved for actual rollback failures.
- **CRLF + no-trailing-newline byte-preservation** (`Hive::Findings::Document#toggle!`): captured the original line ending in a 4th regex group on `FINDING_RE` and reused it on rebuild. CRLF input round-trips as CRLF; a last line without `\n` stays without one. The earlier hardcoded `"…\n"` flattened CRLF and added a trailing newline. Pinned by two new unit tests asserting byte-exact round-trip.
- **Severity carry-over fixed** (`parse_lines`): any `## …` heading that doesn't match `KNOWN_SEVERITIES` (`high|medium|low|nit`) now clears `current_severity` to nil. Multi-word headings like `## Detailed Analysis` previously didn't match the heading regex at all (so subsequent findings inherited the prior severity); short non-severity headings like `## Notes` previously matched and set a fake severity. Both leak vectors closed.
- **`with_task_lock` collision in test helper** (`run_findings_test.rb`): the lock-serialisation test pre-acquires `with_task_lock(execute, …)` then calls toggle. With the new outer/inner lock order, toggle still surfaces `ConcurrentRunError` (TEMPFAIL/75) — the test's contract is preserved without modification.
- **Rollback `git reset` exit status checked** (`rollback_review_change!`): switched from `Open3.capture3` (status discarded) to `ops.run_git!` (raises on non-zero). A failed reset now propagates and the rollback message can't lie about the index state.
- **`Hive::Schemas::ErrorEnvelope.build` helper** added. `Findings#emit_error_envelope` and `FindingToggle#emit_error_envelope` collapsed from ~25 LOC each to ~7 LOC. Per-error structured fields (`candidates` / `id` / `path` / `stage`) are pulled from the typed exception automatically. `approve.rb` left intact (its envelope has different structured fields and the duplication risk is lower now).
- **`Hive::NoSelection` exception** added (exit 64 / USAGE). `select_target_ids` now raises this typed class instead of overloading `Hive::InvalidTaskPath`. `error_kind: "no_selection"` joins the `hive-findings` enum. Closes the agent-facing taxonomy issue where `error_kind: "invalid_task_path"` was being used for "argument set was empty."
- **Targeted no-selection messages**: when `--all` runs against an empty review file, the message names that. When `--severity X` matches nothing, the message lists the available severities.
- **`next_action` consistency**: both `kind: "run"` branches now carry a `reason` field. Previously the "nothing accepted yet" branch omitted `reason`; consumers that branched on its presence saw an inconsistent shape.
- **`pass_from_path` deduped**: moved to `Hive::Findings.pass_from_path(path)` module function. The two duplicate `pass_from_review_path` / `pass_from_path` private helpers in `findings.rb` and `finding_toggle.rb` are gone; both commands call the shared module function.
- **Module-level comment de-transitionalised** (`findings.rb`): "after this module, an agent ticks…" rewritten to "Ticking `[x]` flags a finding to address…" (no transitional reference). Per CLAUDE.md "don't reference the current task/fix" rule.

**Schema changes (`schemas/hive-findings.v1.json`):**

- `ErrorPayload.error_kind` enum gained `no_selection`.
- `ErrorPayload.candidates` items now require `{project, stage, folder}` — mirrors `hive-approve.v1.json` so consumers validating `AmbiguousSlug` across the two endpoints can share validation logic.
- Description added to `ErrorPayload` documenting that `operation` is present iff the error came from a toggle command.

**New wiki pages (round-2):**

- `wiki/modules/findings.md` — public surface of `Hive::Findings` (Document, toggle!, write!, summary, review_path_for, pass_from_path), parsing rules, round-trip guarantees pinned by unit tests, consumer table.
- `wiki/modules/task_resolver.md` — resolution rules (path-shaped vs slug, ambiguity classes, `--project` validation), public API, consumers.
- Reciprocal backlinks: `[[modules/findings]]` on `wiki/stages/execute.md` and `wiki/modules/lock.md`; `[[commands/findings]]` on `wiki/stages/execute.md` and `wiki/modules/lock.md`.
- `wiki/index.md` page count bumped 29 → 31.

**Tests:** 10 new (186 / 735 green; was 176 / 699 on round-1). RuboCop expected clean.

- `test_toggle_preserves_crlf_line_endings` — the `\r\n` round-trip pin.
- `test_toggle_preserves_missing_trailing_newline` — the no-trailing-newline pin.
- `test_non_severity_heading_resets_current_severity` — `## Detailed Analysis` and `## Notes` both clear severity.
- `test_pass_from_path_extracts_integer` — module function pin.
- `test_accept_finding_unions_severity_with_explicit_ids` — combinator behaviour pin.
- `test_accept_finding_with_no_selectors_errors` upgraded to assert `error_kind: "no_selection"` and `error_class: "NoSelection"`.
- `test_hive_findings_candidates_item_shape_pinned` — schema drift guard for the candidate item shape.
- `test_hive_findings_error_kinds_match_producer` updated to include `no_selection`.
- `test_error_subclasses_map_to_their_contract_code` updated to pin `Hive::NoSelection` exit code.

**Findings dismissed (false positives):**

- API-contract reviewer's "UnknownFinding can default to `id: nil`" — only theoretical; no current call site passes nil.
- Adversarial reviewer's `path_target?` containment concern — same behaviour as `approve.rb`'s, intentional.
- Maintainability reviewer's "premature TaskResolver extraction" framing — 4 consumers and the realpath/ambiguity rules are exactly the kind of thing that benefits from one source of truth.

## [2026-04-26T00:30:00Z] hive findings — P3 follow-ups (rollback abstraction, fence awareness, tempfile uniqueness)

**Driver:** Closing the three deferred P3 items from the round-2 review entry above. All three landed together so the rollback contract is consistent across approve and the finding commands.

**Code changes:**

- **`Hive::CommitOrRollback.attempt!` helper** (`lib/hive/commit_or_rollback.rb`, new): consolidates the dual-rescue rollback pattern shared by `Hive::Commands::Approve#attempt_rollback!` and `Hive::Commands::FindingToggle#rollback_review_change!`. The helper owns the rescue + re-raise contract: on undo success, it re-raises the original typed `Hive::Error` (preserving exit codes like `GitError → 70`) or wraps non-typed errors in a generic `Hive::Error`; on undo failure, it raises `Hive::RollbackFailed` carrying both the original cause and the rollback failure. Caller-specific concerns (approve's "source path now exists" precondition, the message templates) stay in the caller. ~30 LOC of duplication removed across the two callers.
- **`Hive::RollbackFailed`** (`lib/hive.rb`, new): typed exception (exit 1 / GENERIC) so the JSON envelope can surface `error_kind: "rollback_failed"`. Lets agents distinguish "commit failed but rollback succeeded → safe to retry" from "commit failed AND rollback failed → fs/git may be inconsistent." Both `hive-findings` and `hive-approve` schemas gained `rollback_failed` in the `error_kind` enum; both commands' `error_kind_for` map the new class.
- **Fenced-code-block awareness** (`Hive::Findings::Document#parse_lines`): triple-backtick / triple-tilde fence tracking. Lines inside a fenced block don't register as headings or findings, so an example finding-shaped line in a reviewer's justification block can't false-positive. Closes a latent bug that would surface as soon as the reviewer prompt template emits fenced examples.
- **Tempfile uniqueness** (`Hive::Findings::Document#write!`, `Hive::Lock.update_task_lock`): tempfile names now append `SecureRandom.hex(4)` to the `Process.pid` suffix. Defends against PID reuse-after-crash where a new process with the same PID would otherwise collide on a stale tempfile path.

**Refactors:**

- `Hive::Commands::Approve#attempt_rollback!` now delegates to the helper. The "source path now exists, can't roll back" precondition stays at the caller; the typed-vs-generic re-raise contract moves to the helper.
- `Hive::Commands::FindingToggle#rollback_review_change!` collapses to the same helper-call shape. Identical contract; only the on_undo block (binwrite + git reset) and message lambdas differ.

**Tests:** 5 new unit tests, 191/758 green (was 186/735). RuboCop clean.

- `test/unit/commit_or_rollback_test.rb` (new) — pins the three helper paths: typed re-raise on undo success, generic wrap on undo success with non-typed original, RollbackFailed on undo failure.
- `test_fenced_code_block_lines_are_ignored_by_parser` — backtick fences with `## High` and `- [ ] foo` content; asserts only real findings are parsed.
- `test_tilde_fenced_code_block_also_ignored` — `~~~` fences too.
- `test_error_subclasses_map_to_their_contract_code` updated to pin `RollbackFailed` exit code.
- Both `hive-findings` and `hive-approve` `test_*_error_kinds_match_producer*` tests updated to include `rollback_failed`.

**Wiki:** No new pages this round (the helper module is small and consumer-focused; documenting it inline in the source comment is sufficient). CHANGELOG covers the user-facing surface.
- `test_commit_failure_rolls_mv_back_to_source` — installs a real `pre-commit` hook that exits 1, asserts mv reverses, exit 70 (GitError), and source restored.
- `test_rollback_failure_surfaces_combined_error_message` — pre-commit hook recreates the source path so rollback can't proceed; asserts the combined "rollback NOT possible / manual recovery" message branch.
- `test_json_error_envelope_on_from_mismatch_carries_wrong_stage_kind` — exercises the JSON error envelope on a `--from` mismatch with `--json`.
- AmbiguousSlug envelope test now pins the full per-candidate key set (`folder`, `project`, `stage`).
- The tautological `test_to_accepts_every_short_stage_name` was deleted; the new `stages_test.rb` covers the constants directly.
