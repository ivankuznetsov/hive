# Keep archive reads separate from active polling

Replaced periodic archive-retention cache composition with an active publisher and explicit on-demand archive refresher. Active and archive publication share a mutex and lifecycle generation; archive errors retain prior rows with an error, while ordinary refreshes remain active-only. Web retains its synchronized source, dependency context and recovery overlay.

Current SQLite DB/WAL, task artifact/state file, per-project stage discovery and same-size policy invalidation remain covered. Parent verification passes 73 tests and 276 assertions; repair and test-coverage reviews found no remaining issue in this unit.
