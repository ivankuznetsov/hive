---
ts: 2026-06-19T09:07:22Z
slug: babysitter-skip-log-path-pin
tags: [babysitter, dry-run, security, wiki]
---

## Babysitter: pin dry-run skip-log path in wrapper launchers

**Action:** Refreshed babysitter dry-run wiki coverage after PR #525 rebased
onto `origin/main`. The merged implementation keeps the newer dry-run
hardening from main and adds the PR's launcher-level
`HIVE_BABYSITTER_DRY_RUN_LOG` pin, so command-local log overrides cannot
redirect skipped-command audit writes outside the worktree-root
`.babysitter-dry-run-skipped.log`.

**Coverage:** Updated [[modules/babysitter]], [[commands/babysit]],
[[testing]], and [[gaps]] to mention skip-log override resistance alongside
the existing real-binary override, gh tempdir config isolation, host-selector
blocking, FIFO/symlink skip-log refusal, and control-character escaping
contracts. Page coverage stayed within existing pages, so [[index]] did not
need a catalog update. Did not edit compiled [[log]].

**Verification:** On the rebased PR branch, `bundle exec ruby -Itest
test/unit/babysitter/dry_run_env_test.rb`, `HIVE_COVERAGE_MIN_LINE=100 bundle
exec rake coverage`, and `bundle exec rubocop --parallel` passed.
