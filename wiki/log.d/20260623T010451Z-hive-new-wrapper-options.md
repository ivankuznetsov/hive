---
date: 2026-06-23
slug: hive-new-wrapper-options
pages: [commands/new, testing]
---

`bin/hive` now normalizes `hive new`'s recognized value options before adding
the free-text terminator. `--workflow`, `--depends-on`, and their assignment
forms continue to reach Thor when they appear after `PROJECT` or after the
task text, while generic control-looking text such as `--help` and malformed
`--json=yes` remains literal task text. Updated [[commands/new]] and
[[testing]] to document the wrapper contract and focused regression coverage.
