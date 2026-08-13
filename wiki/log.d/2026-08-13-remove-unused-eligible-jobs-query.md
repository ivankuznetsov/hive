# Remove unused eligible-jobs query

- Removed `RefactorPatrol::JobStore#eligible_jobs`, which had no production
  caller.
- Retargeted backoff, starvation, and malformed-timestamp coverage to
  `claimable_jobs`, the query used by the architecture patrol scheduler.
