---
pages: [testing]
---

**Action:** Documented the CI coverage-gate failure shape where Minitest reports
`0 failures, 0 errors` but `bundle exec rake coverage` exits 1 after the merged
coverage report. Added the debugging reminder to read the `Coverage gate failed`
section and verify intended `test_*` methods are public, because private test
methods are not discovered and can silently leave defensive branches uncovered.

**Verification:** `bundle exec ruby -Itest test/unit/bot/notification_builders_test.rb`;
`bundle exec ruby -Itest test/unit/web/supervisor_test.rb`;
`bundle exec rake coverage`.
