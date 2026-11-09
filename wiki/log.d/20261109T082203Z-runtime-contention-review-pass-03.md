# Repair runtime contention recovery after review

Mismatched worker custody no longer retains a dead wrapper's live reservation
or wedges lost-outcome cleanup. Process termination distinguishes permission
denial and unverifiable custody from identity mismatch so unresolved workers
still fence successors. Pending valid completion retains precedence over loss.

The contention fixture creates a detached session per supervisor and verifies
worker session custody and group absence before restart replay. Bookkeeping
loss observations remain unsatisfied while retaining their typed reason.
Markerless recovery preserves the original failure-origin lookup key so a
terminal bookkeeping loss can rearm through the ordinary retry ladder.

The nine focused test files pass 255 tests / 1514 assertions. The named runtime
contention gate passes 11 tests / 349 assertions from an ordinary shell; all
11 changed Ruby files pass RuboCop. The implementation evidence corrects the
old session-dependent replay claim. Historical incident proof, hosted checks
and the earlier broad-suite failures remain outside this local qualification.
