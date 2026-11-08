# Complete runtime contention recovery and qualification

Pending receipt verification now canonicalizes the store root while retaining
descendant custody checks. Claimed launches derive the unverifiable-owner
ceiling from persisted claim time and deadline, recheck live custody before
disposition, and replay valid completion first. The exact matching wrapper can
commit its delayed first heartbeat under lease CAS.

Worker registration persists custody through cancellation, timeout and short
exit, including a separately bounded identity-only quiescence cleanup write.
Cancelled workers never receive gate release. Typed bookkeeping reasons now
reach command errors, Execute/Review markers, lost recovery and healer logs.
The pre-pause deadline result nests production passive metrics under the
published checkpoint schema.

The separate runtime contention CI gate exercises a daemon and four real
supervisors, all bookkeeping lock-release/exhaustion operations, invocation
counts, restart replay and both existing workload fixtures. It retains timing
and WAL evidence; no historical long-hold reduction is claimed.

Focused regressions pass (563 tests, 2998 assertions), including the identity
matrix and CAS races; the symlinked-TMPDIR run passes 69 tests / 429 assertions.
The named gate passes 3 tests / 113 assertions. RuboCop passes changed Ruby
files. Wider changed-source coverage cannot complete because unchanged procfs
custody code raises ESRCH for a defunct host 1Password process; the isolated
OpenCode integration file reproduces both errors. Evidence and remaining
uncertainty live in `docs/implementation/runtime-database-contention.md` and
`wiki/gaps.md`.

The broad local suite completed (16,015 tests / 306,010 assertions) with
3 failures and 23 errors, including reproduced OpenCode procfs failures and
a read-only repository snapshot affected by concurrent checkout activity.
The final legacy/malformed-claim-time regression passes in the reconciler
suite (39 tests / 199 assertions).

The unmodified public-help snapshot test passes after the broad workers stop
and the checkout is quiet (2 tests / 52 assertions).
