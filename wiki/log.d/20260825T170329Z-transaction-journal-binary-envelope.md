# Transaction journal stores opaque binary lock bytes via a base64 envelope

- `Hive::WorkflowPackage::TransactionJournal` now wraps opaque binary strings
  (raw `File.binread` lock bytes, ASCII-8BIT with non-ASCII content) in a
  single-key base64 envelope (`{"__binary__" => ...}`) before canonical JSON
  encoding, and unwraps it on read. Canonical text passes through untouched,
  so journals for ASCII locks are byte-identical to the previous format.
- Root cause: `Transaction#activate`/`remove` fed raw binary `old_lock` bytes
  through `CanonicalJSON.generate`, whose string contract is valid NFC UTF-8
  text; any pre-existing lock file with non-ASCII bytes made activation fail
  with `ArgumentError: canonical JSON requires valid UTF-8` and roll back.
- `Transaction#reconcile!` transparently restores the decoded original bytes
  because the envelope is resolved inside `TransactionJournal.read`.
- Regression coverage lives in `test/unit/workflow_package/transaction_test.rb`
  (activation over a `"José"` lock with commit failure and success paths, plus
  reconciliation of an old pointer containing invalid-UTF-8 bytes).
