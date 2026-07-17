# Contain project-config and Patrol failures

**Action:** Wrapped malformed or unreadable per-project YAML in Hive's `ConfigError` contract, added a normal-mode Patrol preflight for missing validation commands, and captured each Patrol worktree's immutable pre-agent HEAD for patch measurement.

**Result:** One bad registered-project config is isolated by existing daemon gates instead of terminating the service and its active workers. Patrol no longer spends reviewer/fixer quota when it cannot validate a fix, while `--dry-run` remains available for review-only scans. A patrol-only CONFIG exit bypasses controller-level project drops and enters scheduler backoff without blocking ordinary tasks or consuming their daily quota. Patch JSON now records `base_sha` and `head_sha`, and attempt diffstats no longer depend on a stale local default branch.

**Coverage:** Config and dispatcher regressions exercise syntax, safe-load,
filesystem-read, inaccessible-parent, and symlink-loop failures; Patrol command
tests prove the preflight runs before agents or state mutation; fixer tests
cover stale default refs, no-op agents, self-contained diffstats, and
failed-attempt provenance.
