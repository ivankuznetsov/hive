## [2026-06-16T01:31:37Z] tests — close PR URL coverage gate gaps

**Action:** Fixed the local `bundle exec rake coverage` failure on PR #491
after the assertion suite passed but the 100% line gate reported three
uncovered defensive branches. Added focused unit coverage for
`Hive::Pr.valid_http_url?` invalid-URI rejection, `Status#pr_url_for`'s quiet
`Errno::ENOENT` degradation when `pr.md` vanishes mid-scan, and
`Dispatcher#reap_dry_run` fatal-log isolation when digest scheduler completion
raises. Verified `bundle exec rake coverage` now reports 100.00% line coverage
with 5450 runs, 21267 assertions, 0 failures, and 0 errors. Did not rebase the
branch because the failure reproduced on the current PR head and was unrelated
to the 4 commits behind `origin/main`.

**Refreshed pages:**
- [[testing]]
