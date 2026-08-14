## Release orphaned-review recovery after PR head drift

- Allowed `observed_head_changed` reconciliation holds to continue bounded
  remote PR-state polling instead of remaining permanently ineligible.
- An open or closed-unmerged PR now releases the universal error-recovery fence,
  allowing an orphaned review to start a fresh generation against the changed
  head.
- A merged PR with the same hold remains blocked before architecture intake and
  automatic archive, preserving the immutable task-head delivery boundary.
- Current dependency, admission, repository, and PR-identity holds outrank
  historical head drift; the poll gate rechecks repository identity before
  GitHub I/O.
- Merged, delivered-elsewhere, and ambiguous drift candidates stop polling
  after their block is durable, while a checkpointed merged fact without that
  diagnostic remains selectable once for crash recovery.
- Added focused regressions for open and closed-unmerged recovery, operational
  hold precedence, repository mismatch, all terminal drift outcomes, and the
  checkpoint-crash window.
