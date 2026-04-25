# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `hive approve TARGET [--to STAGE] [--from STAGE] [--project NAME] [--force] [--json]` — agent-callable equivalent of shell `mv <task> <next-stage>/`. Resolves bare slugs across registered projects; validates terminal-marker on forward auto-advance; records a `hive/state` commit on each move; emits a `hive-approve` JSON document on success AND a structured error envelope on every failure path under `--json` (schema_version 1).
- `Hive::Stages` — single source of truth for the stage list (`DIRS`, `NAMES`, `SHORT_TO_FULL`, `next_dir`, `resolve`, `parse`). `GitOps`, `Status`, `Run`, and `Approve` all delegate to this module so adding a 7th stage is a one-file change.
- New typed exceptions: `Hive::AmbiguousSlug` (carries structured `candidates`), `Hive::DestinationCollision` (carries `path`), `Hive::FinalStageReached` (carries `stage`). Each surfaces extra fields in the JSON error envelope so callers don't parse stderr prose.
- `Hive::Schemas::NextActionKind::RUN` — new kind emitted by `hive approve --json` so an agent can chain to `hive run <new_folder>` deterministically. Closed-enum membership pinned in `test/unit/exit_codes_test.rb`.
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
