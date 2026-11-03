# Repair runtime CI contracts

The exact PR head failed five tests: the quiesce schema rejected PASSIVE drain
metrics, a context database double rejected timeout keywords, two tests expected
pre-bookkeeping error text/classes, and expired proof publication could not roll
its paused candidate back because the write guard rejected an explicit zero
timeout before SQL acquisition.

Restore zero-timeout nonblocking writer attempts while retaining the guard for
exhausted positive budgets. Cover success, immediate SQLite contention and
timeout restoration under controller authority. Extend the closed quiesce
schema for PASSIVE metrics and align the existing test doubles/assertions with
typed bookkeeping/fence failures. The failing-file/database checkpoint passes
167 tests and 994 assertions; the additional lifecycle/schema checkpoint passes
230 tests and 1593 assertions. RuboCop accepts all five touched Ruby files.
Hosted CI revalidation remains separate.
