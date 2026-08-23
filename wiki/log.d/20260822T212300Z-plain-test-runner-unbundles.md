---
title: Keep the plain test runner outside its parent bundle
date: 2026-08-22
---

**Action:** Fixed `bin/test`'s plain-Ruby fallback retaining `RUBYOPT`,
`RUBYLIB`, and RubyGems/Bundler environment from an outer `bundle exec`. On a
host where the fallback `ruby` was older than the bundled Ruby, that immediately
reloaded Bundler and failed its Ruby-version check instead of running the named
test files. The fallback now clears inherited activation before `exec ruby`;
authoritative `HIVE_TEST_REQUIRE_BUNDLE=1` runs remain fail closed.

**Proof:** `test/integration/bin_test_test.rb` injects a poison `RUBYOPT` and
proves the fallback ignores it while loading both supplied files. The focused
integration file and the exact hosted coverage-shard command pass locally.
