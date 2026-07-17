## [2026-07-17T12:06:57Z] hv - guarantee timeout probe termination

**Action:** Changed `bin/hv` to feature-detect timeout kill-after support and invoke supported implementations with a five-second deadline plus one-second KILL grace. Implementations without kill-after support now use the existing process-group watchdog instead of a TERM-only timeout.

**Coverage:** Added a timeout-present regression with a TERM-ignoring helper that verifies candidate fallthrough and process cleanup, and changed the slow-candidate fallback regression to exercise an installed timeout without kill-after support.

**Verified:** `bundle exec ruby -Itest test/unit/hv_test.rb`; `bundle exec rake test` (7,279 runs, 75,181 assertions)

**Links:** [[cli]], [[operating]], [[testing]]
