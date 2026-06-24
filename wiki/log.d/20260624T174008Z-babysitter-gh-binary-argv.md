---
date: 2026-06-24T17:40:08Z
slug: babysitter-gh-binary-argv
pages: [modules/babysitter, testing]
---

## babysitter - normalize gh stub argv before classification

`bin/hive-babysitter-stub-gh` now mirrors the git dry-run stub by converting
`ARGV` entries to binary strings before any regex-based classification. A
malformed external-host `gh api` operand such as an invalid/non-UTF-8 URL now
falls through the default-deny skip path, writes the dry-run audit log, and
prints the skipped command without an `ArgumentError` backtrace.

Added focused `test/unit/babysitter/dry_run_env_test.rb` coverage for the gh
invalid-argv skip path and refreshed [[modules/babysitter]] / [[testing]].
