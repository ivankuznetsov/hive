# Bypass the transition guard when benchmark plan review is disabled

- Live Pi proof showed `plan_review.enabled: false` suppressed reviewer
  dispatch, but the subsequent `develop` transition still failed because no
  current plan-review resolution existed.
- Made transition prepare, locked verification, and execute-entry validation
  return without review authority when the already-validated configuration
  explicitly disables plan review.
- Kept ordinary projects fail-closed: only the benchmark-only process grant can
  make a disabled configuration valid.
- Added focused coverage proving the disabled path initializes no orchestrator,
  requires no observation, and writes no execute-entry adoption artifact.
