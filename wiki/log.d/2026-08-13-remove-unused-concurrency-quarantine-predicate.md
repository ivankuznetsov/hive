# Remove unused concurrency quarantine predicate

- Removed `Daemon::ConcurrencyController#quarantined?`, which had no
  production caller.
- Retargeted tests to the production `can_dispatch?` decision and operational
  snapshot while preserving quarantine, reset, and digest non-leak behavior.
