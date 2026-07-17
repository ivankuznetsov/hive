## [2026-07-17T11:54:20Z] babysitter - scrub Go HTTP debug env before gh passthrough

**Action:** Fixed patrol finding `command-bin-hive-babysitter-stub-gh-2` by deleting `GODEBUG` before the dry-run stub executes a real allowlisted `gh` read. This prevents Go HTTP/2 diagnostics such as `http2debug=2` from writing authenticated request headers to captured stderr and babysitter logs.

**Coverage:** Added a focused allowlisted `gh api rate_limit` regression whose fake transport emits its bearer header only when `GODEBUG=http2debug=2` survives, then verifies the real command ran without any authorization value reaching stderr.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[testing]]
