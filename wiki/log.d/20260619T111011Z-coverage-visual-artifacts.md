## [2026-06-19T11:10:11Z] testing — close visual artifact coverage gaps

**Action:** Closed the Ruby CI coverage failure on PR #515. The branch's test assertions were already green, but `bundle exec rake coverage` failed the 100% line gate on unexercised visual-artifact/Screenote branches.

**Tests:** Added focused unit coverage for:

- `Hive::ScreenoteUploader` invalid JSON success bodies and default Net::HTTP timeout forwarding.
- `Hive::Stages::Artifacts` unexpected upload exceptions and missing `media/` directory skips.
- `Hive::Config` non-string `screenote.api_token` validation.
- `Hive::Daemon::Dispatcher` dry-run digest completion errors while still reaping the pseudo-child.

**Verification:** `bundle exec rake coverage` now passes locally with `100.00% (24410/24410)` line coverage and `5498 runs, 21734 assertions, 0 failures, 0 errors`.

**Docs:** Updated [[testing]] so the visual-artifact/Screenote coverage contract is explicit.
