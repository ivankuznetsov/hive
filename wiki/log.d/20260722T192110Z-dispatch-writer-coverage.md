---
title: Durable dispatch-writer failure coverage
date: 2026-07-22
tags: [bot, daemon, attempts, testing]
---

Hosted CI on PR #833 completed 10,057 tests with zero failures but rejected the
result at 99.99% line coverage. The six uncovered lines were the durable bot
dispatch writer's generic admission-failure cleanup and real project/stage task
resolution path.

Focused tests now prove an unexpected admission error removes the still-
unclaimed delivery and re-raises the identical exception, while capacity
deferral continues leaving its request pending. A resolver-boundary test proves
the slug is scoped by both project and `--from`/`--stage`, including the no-stage
case. [[modules/bot]] now describes that durable foreground admission contract;
the focused test remains the executable proof.

**Verified:** Exact failing seed replay of `test/unit/bot/dispatch_request_writer_durable_test.rb` (4 runs, 13 assertions, 0 failures, 0 errors) and RuboCop (1 file, no offenses).

**Links:** [[modules/bot]], [[testing]], [[state-model]], [[modules/daemon]]
