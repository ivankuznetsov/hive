# Cover runtime bookkeeping failure and recovery paths

The CI coverage merge reported 60 unexecuted lines across attempt bookkeeping,
dispatch, reconciliation, supervision, and runtime database/payload storage.
Added regression assertions in the seven existing owning test files for
validation failures, completion replay, custody and publication guards,
ambiguous admission/registration, storage failures, and SQL cleanup errors.

The focused seven-file run passed 239 tests and 1,363 assertions. Merged local
coverage exercised all 60 lines listed by CI. Production behavior and the exact
100% CI coverage threshold are unchanged; the runner will verify the full
pull-request head after this commit.
