---
title: Prune persisted legacy benchmark agent shims
type: fix
date: 2026-11-03
pages: [modules/workflows, testing, gaps]
tags: [bench, agent, shell, cleanup]
---

The non-sealed packaged stage caller now removes exactly `codex`, `pi`, and
`grok` from its managed bin before PATH export and agent preflight/resume
routing, and repeats cleanup before review. Directory setup/validation and
direct removal-status failures have distinct `HB_ERROR` diagnostics and stop
the cell with exit 4. Sealed controller behavior and the explicit Pi launcher
are preserved.

Hive tested revision
[`2b76f330c79d6395064dcc64d54772a3ae31150d`](https://github.com/ivankuznetsov/hive/commit/2b76f330c79d6395064dcc64d54772a3ae31150d)
passed both focused workflow test files: 63 tests, 2729 assertions, no failures,
errors, or skips. Full-caller fixtures cover fresh/reused directories,
preflight, execute/review resume, review replanting, symlinks, unrelated state,
real unprivileged unlink denial, and repair/retry. The existing Pi extension
argv test remains green. Shell syntax, ShellCheck 0.11.0, and the new test's
Ruby style check passed. The measured new file is included in the default
suite and one coverage shard. No full suite or exhaustive coverage was run.

Canonical hive-bench revision `243ef7bb7e2cb3f6ecbe2d5fe3f3ab9c83cff326`
was inspected during planning, not fixed or tested here. Its Pi
self-resolution repair and future full-caller repeatability proof remain a
separate follow-up in [[gaps]]. That page also records the accepted Hive
stale-`claude` exposure and stale-`gh` plan/execute window. [[testing]] maps
ownership across the divergent snapshots; shared shell linting does not imply
behavioral parity.
