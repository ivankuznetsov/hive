# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `hive approve TARGET [--to STAGE] [--project NAME] [--force] [--json]` — agent-callable replacement for shell `mv <task> <next-stage>/`. Resolves bare slugs across registered projects; validates terminal-marker on forward auto-advance; records a `hive/state` commit on each move; emits a `hive-approve` JSON document (schema_version 1) under `--json`. Stable exit codes: `Hive::InvalidTaskPath` (64), `Hive::WrongStage` (4), `Hive::Error` (1) for the four failure modes.
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
