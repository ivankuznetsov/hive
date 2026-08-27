# Add an explicit benchmark-only plan-review opt-out

- Kept built-in coding plan review enabled and non-disableable for ordinary
  project loads.
- Allowed `plan_review.enabled: false` only when the launching process supplies
  `HIVE_BENCH_ALLOW_DISABLED_PLAN_REVIEW=1`, for reproducibility of historical
  benchmark generation.
- Added focused coverage proving the granted load succeeds and the same config
  still fails closed when the environment grant is absent.
- Full Pi/OpenCode campaign parity remains live verification, not a result
  claimed by this fragment.
