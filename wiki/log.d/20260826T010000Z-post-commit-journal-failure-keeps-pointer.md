# Post-commit journal failure no longer rolls back the workflow pointer

- **Date**: 2026-08-26
- **Scope**: `lib/hive/workflow_package/transaction.rb`
- **Trigger**: Patrol finding `architecture-lib-hive-workflow-package-part-4-20260826T000046Z-959eda8b-1`

## What changed

`Transaction#run` previously used one unconditional rescue handler for the
whole activation. A failure after a successful `commit.call` — for example an
exception while writing the `commit_completed` journal phase — restored the
old pointer and cleared the journal even though HEAD already contained the new
lock. That left HEAD at the new selection while the working lock file held the
old one, with `.transaction.json` deleted so `reconcile!` could not repair it.

Now a local `committed` flag marks the irreversible boundary: once
`commit.call` returns, failures re-raise without restoring the old bytes or
clearing the journal. The surviving `commit_started` phase lets `reconcile!`
resolve against git via `committed_pointer?`, which keeps the new lock when
HEAD matches and restores the old one when it does not.

Failures before or during `commit.call` keep the original rollback semantics.

## Tests

- `test/unit/workflow_package/transaction_test.rb`:
  `test_post_commit_journal_failure_keeps_new_pointer_and_surviving_journal`

## Uncertainty

None recorded.
