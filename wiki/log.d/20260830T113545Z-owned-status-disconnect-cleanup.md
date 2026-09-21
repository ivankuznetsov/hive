---
title: Owned live-status disconnect cleanup
date: 2026-08-30
tags: [web, turbo, action-cable, lifecycle, cleanup]
---

Hive web's permanent status stream source now owns one explicit lifecycle
boundary. Each application setup or retry attempt creates a dedicated Action
Cable consumer, while a transport reconnect retains that attempt. The owner
contains the current attempt, retry and pending-release timers, catch-up work,
and lifecycle state; identity guards make late callbacks, consumers, timers,
and queued connection `open`/`reopen` work inert after retirement. The code no
longer reads or mutates turbo-rails' shared consumer cache or scans a shared
subscription registry to make cleanup decisions.

Pre-confirmation detach still waits for confirmation, rejection, or disconnect
so server registration precedes unsubscribe. If none arrives within five
seconds, the bounded custodian closes its dedicated transport before releasing
the local subscription handle. Confirmed teardown is failure-complete and
fallback-only: it records the exact first thrown value, tries every applicable
cleanup operation, uses consumer disconnect as the primary transport shutdown,
and attempts reconnect-disabled connection/raw-socket closes only while the
captured socket remains `OPEN` or `CONNECTING`. Direct internal callers receive
that first error after terminal finalization; custom-element and async entry
paths warn after completing DOM, state, and successor obligations.

The focused lifecycle suite is now
`web/test/system/status_stream_source_test.rb`. Its 16 cases retain the two real
pre-confirmation ordering/bounded-cleanup scenarios and add teardown failure,
exact-close, stale-work fencing, setup/terminal retry, supersession, same-
attempt reconnect, fresh-attempt recovery, and deterministic transport-count
coverage. Dedicated ownership intentionally means one Cable transport per live
source; supersession may briefly add one bounded retiring predecessor, and
detach returns to zero after any bounded pending release. Many-tab/load, multi-
worker convergence, and live-Docker capacity evidence remain open.

Verification obtained for this change:

- `mise x ruby@3.4.7 -- bundle exec rails test test/system/status_stream_source_test.rb`
  from `web/`: 16 runs, 201 assertions, 0 failures, 0 errors, 0 skips.
- `mise x ruby@3.4.7 -- bundle exec rails test
  test/system/kanban_board_test.rb test/system/pipeline_flow_test.rb
  test/system/task_workspace_test.rb` from `web/`: 47 runs, 517 assertions,
  0 failures, 0 errors, 0 skips.
- `mise x ruby@3.4.7 -- bundle exec rails test
  test/channels/status_channel_test.rb test/integration/status_test.rb` from
  `web/`: 24 runs, 146 assertions, 0 failures, 0 errors, 0 skips.
- `mise x ruby@3.4.7 -- bin/rubocop` inspected 137 web files with no offenses;
  `mise x ruby@3.4.7 -- bin/importmap audit` found no vulnerable packages.
- Source and Wiki ownership searches found no shared-cache/registry decision,
  terminal stopped state, or stale current-page recovery claim; `git diff
  --check` and Wiki frontmatter parsing also passed.

The repository-wide `mise x ruby@3.4.10 -- bundle exec rake test` checkpoint
reproduced the plan's unrelated environment-dependent baseline failure after
128 runs and 1,273 assertions (1 failure, 1 skip):
`AgentCliRuntimeRuntimeTest#test_compile_preserves_each_builtin_prompt_transport`
expected `grok`, while mise resolved the installed Grok executable to its
absolute path. `git diff --exit-code c133790bfe..HEAD --
components/agent-cli-runtime` passed, proving this branch does not change that
component; every focused web/status gate above is green.
