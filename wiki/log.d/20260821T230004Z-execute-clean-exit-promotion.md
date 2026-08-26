# Complete safe execute residue in the original run

**Action:** When the 4-execute runner records `ERROR reason=dirty_worktree` but
the generic stage-exit CleanExit hook safely auto-commits that in-scope residue,
Hive now runs the existing guarded committed-residue boundary immediately and
publishes `EXECUTE_COMPLETE`. This avoids an unnecessary second harness pass
while preserving owned-worktree, expected-branch, ancestry, new-commit, and
cleanliness validation. Research-mode execution is excluded so its structured
final-message evidence contract remains authoritative.

Unsafe, out-of-scope, or otherwise uncommittable residue retains the existing
error and explicit recovery behavior.
