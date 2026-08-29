# Backward workflow rewinds now rearm traversed stages

**Action:** Changed the supported backward `hive approve --to` recovery path
from a folder-only move into a controller-owned workflow rewind. Under the
existing commit and task locks, Hive now snapshots and clears every recognized
marker from descriptor state files in the destination-through-source interval,
de-duplicates shared files, preserves prose and files outside the interval, and
restores exact bytes if validation or commit fails. Added coding integration
coverage for `7-artifacts` to `6-review`, commit-failure rollback, partial
multi-file failure rollback, and symlink refusal.

**Why:** A task moved back from artifacts to review retained
`REVIEW_COMPLETE` in `task.md` and `ERROR` in `artifact.md`. Review therefore
reported itself already complete and the next artifacts visit immediately
returned the old error, even though the documented recovery command succeeded.

**Verification:** `test/unit/commands/approve_test.rb` and
`test/integration/run_approve_test.rb` pass; RuboCop is clean for the changed
Ruby files. Live managed-workflow rewind evidence remains tracked in
[[gaps]].
