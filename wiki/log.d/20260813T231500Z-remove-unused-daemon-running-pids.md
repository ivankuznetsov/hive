## Remove unused daemon running-PID accessor

- Removed `Daemon::ConcurrencyController#running_pids`, whose only callers
  were two direct unit assertions and which exposed no documented operational
  contract.
- Retargeted the assertions to the live project/slug identity predicate while
  retaining aggregate in-flight bookkeeping coverage.
