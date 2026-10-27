# 2026-10-27 — Doctor accepts commit-SHA plugin versions for unconstrained packages

- `hive doctor` no longer reports `incompatible` for a managed skill whose
  package requirement is `>= 0` when the agent reports a commit-SHA version,
  as Claude Code does for plugins installed from a git marketplace (for
  example `pr-review-toolkit` at `fa59bc903774`). Any non-empty version
  satisfies an unconstrained requirement; constrained packages still parse
  the version and report `stale` or `incompatible`.
