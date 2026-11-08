# 2026-10-02 — Task-owned CI failures stay deterministic across deploys

- The recovery coordinator scopes its retry ladder and identical-failure
  count to the Hive runtime digest, so a new deploy can cure a Hive-caused
  failure. hivedev F2's `REVIEW_CI_STALE` (its own smoke test, red the same
  way every time) was reset by every deploy. The healer kept retrying it, and
  each retry ran three CI-fix agents and leaked a 29k-file smoke tmpdir. That
  exhausted the tmpfs `/tmp` inodes twice.
- `RecoveryCoordinator::TASK_OWNED_FAILURE_MARKERS` (`review_ci_stale`)
  ignores the runtime digest in the durable retry count and the
  identical-failure series. These failures park as `deterministic_failure`
  after the threshold regardless of deploys. Hive-caused failures keep the
  per-runtime reset.
