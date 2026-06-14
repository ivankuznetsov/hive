## [2026-06-14T10:58:28Z] testing - eval dispatch capture follows queued bot commands

**Action:** Updated the eval harness after the full `test:eval` suite exposed stale
child-supervisor-only expectations for bot callbacks. The production supervisor
routes queue-routable Hive verbs through `DispatchRequestWriter`; the eval
harness now injects a fake writer and exposes `Harness#dispatched_commands` so
scenarios can assert command intent across queued requests, sequence
continuations, and non-queue child spawns.

**Verification:** Ran the focused failing eval scenario files, the full
`HIVE_EVAL_NO_JUDGE=1 bundle exec rake test:eval` suite, RuboCop on touched
Ruby files, and the default `bundle exec rake test` suite.

**Refreshed pages:**
- [[testing]]
