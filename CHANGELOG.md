# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial public release of Hive — folder-as-agent pipeline driving a six-stage filesystem state machine.
- CLI commands: `hive init`, `hive new`, `hive run`, `hive status`.
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
