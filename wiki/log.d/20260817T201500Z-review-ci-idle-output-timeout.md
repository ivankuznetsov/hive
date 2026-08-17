---
title: Review CI runner gains an idle-output deadline
date: 2026-08-17
tags: [review, ci, timeout]
---

`Stages::Review::CiFix.run_ci_once` now accepts an optional idle-output
deadline plumbed from `timeout_sec.review_ci_idle`, mirroring patrol's
`timeout_sec.patrol_idle` split: `timeout_sec.review_ci` remains the
wall-clock runaway backstop, while a CI child that produces no combined
stdout+stderr for the idle window is TERM/KILL'd immediately with a
`CommandError` carrying an `idle-output timeout` message through the existing
`:error` path. The pipe reader stamps a mutex-guarded monotonic pulse per
drained chunk — including capped-and-dropped bytes, which are still proof of
life. Unset or non-positive disables the idle deadline; existing configs are
unchanged. See [[stages/review]].
