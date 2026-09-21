# Live-status ownership sweep

Revalidated PR #1349 against current main and preserved its dedicated consumer,
retired-callback fence, confirmation-ordered release, and bounded predecessor
ownership. Consolidated three identical setup exception paths into one without
adding an abstraction. The original focused browser matrix passed 27 tests and
292 assertions; current-main integration is validated separately in the PR.

The system-test file size is not a repository-contract violation. Its distinct
fault scenarios remain explicit; live many-tab transport capacity remains a
known limitation rather than an inferred performance claim.
