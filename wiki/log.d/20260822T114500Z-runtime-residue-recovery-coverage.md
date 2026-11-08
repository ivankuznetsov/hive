# Artifact runtime residue recovery proves its fail-closed branches

**Problem:** `RuntimeResidueRecovery` landed with only its happy path, one
rejection sweep, and the not-applicable guard under test. Eighteen lines — every
remaining fail-closed branch — were unreachable from the suite and broke the
exact-100% line gate.

**Change:** `runtime_residue_recovery_test.rb` now exercises the clean-worktree
result, unreadable `git status` (including the bounded-output overflow
diagnostic), non-UTF-8 residue paths, the prepared-journal resume and its
conflict rejections, an unparsable journal, residue rewritten after journaling,
a corrupted quarantine entry, containment failures for both an escaping entry
path and a symlinked parent, the total-byte budget, parent pruning that stops at
a tracked file, and a quarantine that leaves the worktree dirty.

A `journal` test helper writes the prepared receipt a killed recovery would
leave behind, so resume and containment paths are exercised without racing a
real interruption; its `entries:` override is what forges entries a correct run
could never journal.

**Verification:** `ruby -Itest -Ilib test/unit/artifacts/runtime_residue_recovery_test.rb`
is green, and Ruby's `Coverage` reports zero uncovered lines in
`lib/hive/artifacts/runtime_residue_recovery.rb` from that file alone.

See [[artifacts]].
