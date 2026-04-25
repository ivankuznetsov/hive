# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `hive findings TARGET [--pass N] [--project NAME] [--json]` — list GFM-checkbox findings in `<task>/reviews/ce-review-NN.md` (latest pass by default; `--pass N` for a specific pass). Read-only; emits text table or single-line `hive-findings` JSON document. Schema version 1.
- `hive accept-finding TARGET [ID...] [--severity S] [--all] [--pass N] [--project NAME] [--json]` — tick `[ ]` → `[x]` on review findings so they are re-injected into the next implementation pass via `Hive::Stages::Execute#collect_accepted_findings`. Selectors (positional IDs, `--severity high|medium|low|nit`, `--all`) are unioned. Atomic write (tempfile + rename), task-lock'd, audit-trail commit on hive/state. Idempotent — already-accepted findings are no-ops and excluded from the `changes` array.
- `hive reject-finding TARGET [ID...] [--severity S] [--all] [--pass N] [--project NAME] [--json]` — inverse: tick `[x]` → `[ ]`. Same selectors, same locking, same idempotency.
- `Hive::Findings` module — parser + writer for review files. `Document` exposes a `findings` list (1-based stable IDs in document order), `summary` (total / accepted / by_severity counts), `toggle!(id, accepted:)`, and atomic `write!`. `review_path_for(task, pass:)` resolves the latest or named-pass review file.
- `Hive::TaskResolver` (`lib/hive/task_resolver.rb`) — extracted slug-or-folder resolution shared between `approve`, `findings`, `accept-finding`, and `reject-finding`. `Hive::Commands::Approve` now delegates to it; future commands can compose on the same resolver.
- `Hive::NoReviewFile` (exit 64 / USAGE) and `Hive::UnknownFinding` (exit 64 / USAGE) typed exceptions; `UnknownFinding` carries the offending `id` for the JSON error envelope.
- `schemas/hive-findings.v1.json` — published JSON Schema (draft 2020-12) with `oneOf` over `ListPayload`, `TogglePayload`, and `ErrorPayload`. `test/unit/schema_files_test.rb` pins required-key sets and the `error_kind` enum against the producer's emission.
- `hive approve TARGET [--to STAGE] [--from STAGE] [--project NAME] [--force] [--json]` — agent-callable equivalent of shell `mv <task> <next-stage>/`. Resolves bare slugs across registered projects; validates terminal-marker on forward auto-advance; records a `hive/state` commit on each move; emits a `hive-approve` JSON document on success AND a structured error envelope on every failure path under `--json` (schema_version 1).
- `Hive::Stages` — single source of truth for the stage list (`DIRS`, `NAMES`, `SHORT_TO_FULL`, `next_dir`, `resolve`, `parse`). `GitOps`, `Status`, `Run`, and `Approve` all delegate to this module so adding a 7th stage is a one-file change.
- New typed exceptions: `Hive::AmbiguousSlug` (carries structured `candidates`), `Hive::DestinationCollision` (carries `path`), `Hive::FinalStageReached` (carries `stage`). Each surfaces extra fields in the JSON error envelope so callers don't parse stderr prose.
- `Hive::Schemas::NextActionKind::RUN` — new kind emitted by `hive approve --json` so an agent can chain to `hive run <new_folder>` deterministically. Closed-enum membership pinned in `test/unit/exit_codes_test.rb`.
- `Hive::Schemas::NextActionKind::APPROVE` — `hive run --json` now emits `kind: 'approve'` (was `kind: 'mv'`) for `:complete` and `:execute_complete` markers, with a `command: "hive approve <slug> --from <stage>"` field. `MV` stays in the closed enum (per the additive-only policy) but the canonical agent action is now `hive approve`. Back-compat `from` / `to` fields are kept on the next_action object.
- `schemas/hive-approve.v1.json` — published JSON Schema (draft 2020-12) for external consumers. Validates the success payload, the structured error envelope, and the closed `NextAction.kind` enum. `Hive::Schemas.schema_path("hive-approve")` resolves the absolute path. `test/unit/schema_files_test.rb` pins the schema file's required-key set against the producer's emission so drift fails at test time.
- `.hive-state/.gitignore` — `hive init` now bootstraps a gitignore at the .hive-state root that excludes `stages/*/*/.lock`, `stages/*/*/.lock.tmp.*`, `stages/*/*/*.markers-lock`, and `.commit-lock`. Per-task lock metadata (PIDs, process_start_time) is per-process and was previously committed in hive/state on every `hive run` and `hive approve`.
- Symlink hardening on `hive approve`: `resolve_target` realpaths the resolved folder before passing it to `Task.new`, so a slug-named symlink at `.hive-state/stages/<N>/<slug>` pointing to `/tmp/leaked` is rejected at the PATH_RE check instead of being moved as a symlink.
- TOCTOU robustness in `move_task!`: a non-hive process that `mkdir`s the destination between the pre-check and the rename surfaces as `Hive::DestinationCollision` (typed) instead of a bare `Errno::ENOTEMPTY` trace. Direct `File.rename` is wrapped in a rescue for `ENOTEMPTY` / `EEXIST` / `EISDIR`; cross-device moves fall back to `cp_r` + `rm_rf`.
- `Hive::InternalError` (exit 70 / SOFTWARE) — catch-all wrapper for non-`Hive::Error` exceptions in `Approve#call`. With `--json`, a structured envelope is still emitted (no Ruby trace on stderr); without `--json`, the user sees a friendly `hive: internal error: <Class>: <msg>` and a stable exit code instead of an unhandled trace. Closes the silent-failure path where Errno::ENOSPC, SystemCallError, or an unhandled Open3 failure escaped the rescue boundary.

### Changed (P3 hardening — round 3)

- `Approve#record_commit_or_rollback!` rescue narrowed from `StandardError` to `Hive::Error, SystemCallError`. The previous broad rescue was swallowing typed errors (e.g. `Hive::GitError` exit 70) and rewrapping them as generic exit 1, erasing the contract code. Typed errors now re-raise unchanged after rollback so wrappers see the documented exit code.
- `Approve#attempt_rollback!` (extracted) now wraps the rollback `FileUtils.mv` in its own rescue. If the rollback itself fails (cross-device, EACCES, source re-created), both the original commit failure AND the rollback failure surface in one combined message — operator has the full picture for manual recovery.
- `Approve#cross_device_move!` (extracted from `move_task!`) cleans up the partial destination if `cp_r` fails mid-flight (ENOSPC, EACCES on a child file, EIO). Previously a partial copy plus an intact source could leave the next retry hitting a phantom collision with no indication of where the real data lived.
- `Approve#cleanup_orphan_task_lock` now rescues only `Errno::ENOENT` (expected — concurrent process beat us to delete). Other I/O errors propagate so the rollback path runs.
- `Approve#source_has_tracked_files?` now checks `Open3` exit status. A failed `git ls-files` (corrupt index, missing repo) was previously interpreted as "no tracked files," silently skipping the source-side `git add` and leaving a tree-vs-index drift. Now raises `Hive::GitError`.
- `Hive::Stages.parse(dir)` validates `DIRS.include?(dir)` before splitting. `parse("99-foo")` returns nil instead of `[99, "foo"]` so a hand-constructed stage string can't silently slip past validation downstream.
- `Hive::Stages.next_dir(idx)` raises `ArgumentError` for non-integer or `idx < 1` instead of silently returning whatever `DIRS[idx]` gives. Off-by-one bugs surface at the call site rather than as an indistinguishable nil "final stage".
- `Hive::GitOps::STAGE_DIRS` and `Hive::Commands::Status::STAGE_ORDER` aliases removed; both classes now reference `Hive::Stages::DIRS` directly. Closes the half-migration smell flagged in review.

### Added — round 3

- `wiki/modules/stages.md` — wiki page for the new `Hive::Stages` module per the project's convention of one wiki page per code module.
- `test/unit/stages_test.rb` — pins `DIRS` / `NAMES` / `SHORT_TO_FULL` shapes, `resolve` / `next_dir` / `parse` semantics, and the new validation behavior (parse rejects unknown stages, next_dir raises on out-of-range).
- `test/integration/run_approve_test.rb` — rollback-on-commit-failure test (uses a real `pre-commit` hook that exits 1, asserts mv reverses + GitError exit code 70 surfaces) and a paired rollback-also-fails test for the manual-recovery message branch. Plus `--from` mismatch JSON error envelope test, full per-candidate key-set pin on `AmbiguousSlug`. The tautological `test_to_accepts_every_short_stage_name` was deleted (covered by the new unit tests in `test/unit/stages_test.rb`).
- `--from STAGE` on `hive approve`: asserts the task is at the named stage before advancing. Mismatch raises `WrongStage` (4). Idempotency lever for retry loops — a network blip mid-call no longer silently double-advances on the next attempt.
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` into `help <cmd>` before Thor dispatch, so the convention agents try first works.
- Thor `enum:` constraint on `--to` and `--from`: invalid stage values fail at parse time before any code in `Approve` runs, and the valid set is listed in `hive help approve` output.

### Changed

- `hive approve` JSON schema: split combined `from_stage` / `to_stage` strings into `from_stage` (bare) + `from_stage_index` + `from_stage_dir` (combined), mirroring `hive-run`'s `stage` / `stage_index` shape. Added `ok`, `noop`, `direction`, `forced`, `from_marker`, `next_action` fields. Schema version stays at 1 (no consumers in the wild yet).
- `hive approve` git commit is now slug-scoped: `git add -A stages/<src>/<slug> stages/<dst>/<slug>` instead of staging the whole parent stage directories. Sibling-task changes in the same stage no longer get swept into the approve commit, fixing audit-trail corruption.
- `hive approve` is now atomic-with-rollback: `with_commit_lock` is acquired BEFORE the move so contention surfaces before any filesystem mutation; `with_task_lock` blocks concurrent `hive run` on the same task; if the commit fails (pre-commit hook abort, lock timeout mid-flight, etc.) the move is reversed and the original error is wrapped in `Hive::Error` so fs and git don't diverge.
- `hive approve` raises `Hive::FinalStageReached` (exit 4, `WRONG_STAGE`) instead of bare `Hive::Error` (exit 1) when asked to advance past `6-done`. Distinguishes "no further stage" from a recoverable destination collision (still exit 1) so retry loops can branch deterministically.
- `hive approve` raises `Hive::AmbiguousSlug` when a bare slug exists at multiple stages within one project (was: silent lowest-stage-wins). The previous heuristic was wrong for the partial-failure-recovery case where the lower stage is the stale leftover. Pass an absolute folder path or `--to` to disambiguate.
- `hive approve --to <current-stage>` is now a clean no-op (exit 0, `noop: true` in JSON) instead of triggering the destination-collision branch.
- `hive approve` text-mode output sends the `next: hive run …` hint to stderr instead of stdout, so a caller piping stdout through `jq` (without remembering `--json`) doesn't get prose mixed with data.
- `hive approve` deletes the per-process `.lock` file at the destination after the move so it isn't tracked in the slug-scoped commit.
- Initial public release of Hive — folder-as-agent pipeline driving a six-stage filesystem state machine.
- CLI commands: `hive init`, `hive new`, `hive run`, `hive status`, `hive approve`.
- Six pipeline stages: `1-inbox`, `2-brainstorm`, `3-plan`, `4-execute`, `5-pr`, `6-done`.
- Orphan-branch state model (`hive/state` checked out as a separate worktree at `<project>/.hive-state/`).
- Per-task `.lock` (with PID-reuse defence via `/proc/<pid>/stat` start time, macOS `ps -o lstart=` fallback) and per-project `.commit-lock` (flock).
- Atomic marker writes (tempfile + rename under a `.markers-lock` sidecar).
- Prompt-injection nonce wrapper (`<user_supplied_<hex16>>…</user_supplied_<hex16>>`) on every stage template.
- SHA-256 integrity checks on `plan.md` and `worktree.yml` around both the implementation and reviewer passes.
- PR body secret-scan in the `5-pr` stage (api-key / AWS / GitHub-token / PEM patterns).
- Runtime claude version check (`Hive::Agent.check_version!`) wired into every active-stage spawn, memoized per `bin` path.
- Wiki knowledge base under `wiki/` with index, architecture, state-model, decisions (ADRs), per-stage and per-module pages.
- CI: GitHub Actions running tests, RuboCop (37signals omakase), Brakeman, and `bundler-audit`.
- Dependabot configuration (bundler weekly, GitHub Actions weekly).
- `--json` output mode for `hive status` and `hive run`. Each emits a single JSON document on stdout with a `schema` + `schema_version` header (current: `hive-status` / `hive-run`, version 1).
- Documented exit-code contract: `Hive::ExitCodes` constants and per-`Hive::Error`-subclass codes mapped through `bin/hive` (0 success, 2 already-initialised, 3 task in `:error`, 4 wrong stage, 64 usage, 70 software, 75 retryable lock contention, 78 config).
- New `Hive::TaskInErrorState`, `Hive::WrongStage`, `Hive::AlreadyInitialized` exceptions for the new exit-code mappings — all three now actually raised by their corresponding call sites (run.rb on `:error` marker; inbox.rb when `hive run` is invoked on `1-inbox/`; init.rb on a second-init).
- `Hive::SCHEMA_VERSIONS` registry: single source of truth for the JSON contract version per schema (`hive-status`, `hive-run`).
- `Hive::Schemas::NextActionKind` closed enum (`EDIT`, `MV`, `RECOVER_STALE`, `NO_OP`, plus `ALL`) shared between the producer (`run.rb`) and the JSON regression tests.

### Changed

- `hive run` exits with code `3` (not `1`) when a stage records a `:error` marker — distinguishes a runner-level failure from an agent-recorded task failure.
- `hive run` on a `1-inbox/` task now raises `Hive::WrongStage` (exit 4) instead of warning + returning 0, so agent callers can branch on the wrong-stage condition.
- `hive init` on an already-initialised project raises `Hive::AlreadyInitialized` (exit 2) through the rescue path; behaviour is identical to the previous bare `exit 2` but the contract now flows through one channel.
- `with_captured_exit` test helper centralised in `test/test_helper.rb` (previously duplicated in **four** integration test files — the `init_test.rb` copy was missed in the first pass).
