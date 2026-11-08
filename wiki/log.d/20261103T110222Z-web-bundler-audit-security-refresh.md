# 2026-11-03 — Refresh vulnerable web sanitization dependencies

- Updated `web/Gemfile.lock` to `nokogiri` 1.19.7, `loofah` 2.25.3, and
  `rails-html-sanitizer` 1.7.2 after CI's current advisory database reported
  vulnerabilities in the prior lockfile.
- Verified with `BUNDLE_PATH=/tmp/hive-pr1595-bundle bundle exec bundler-audit
  check --gemfile-lock Gemfile.lock`, which reported no vulnerabilities.
- The root `bin/test --changed --list` selector remains unverified locally:
  its root bundle is not installed in this checkout.
