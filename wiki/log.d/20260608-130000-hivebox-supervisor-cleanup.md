## [2026-06-08T13:00:00+01:00] hivebox — restore supervisor process state after run exits

**Action:** Fixed an order-dependent web test failure after rebasing PR #300:
`Hive::Web::Supervisor#run` published `HIVEBOX_SUPERVISOR_PID` and installed
TERM/INT/HUP traps, but did not restore that process-global state when the run
loop returned in-process. A later Telegram token-save route inherited the stale
pid and signalled the test process instead of redirecting reliably. `run` now
restores the previous env value and signal handlers in its ensure path, while
the supervisor unit test asserts that child startup still sees the supervisor
pid before cleanup.

**Tests:**
- `bundle exec ruby -Itest -e 'require File.expand_path("test/unit/web/supervisor_test.rb"); require File.expand_path("test/unit/web/telegram_routes_test.rb")' -- --seed 37831`
- `bundle exec ruby -Itest -e 'Dir["test/unit/web/*_test.rb"].sort.each { |f| require File.expand_path(f) }; require File.expand_path("test/integration/web/approve_flow_test.rb")' -- --seed 37831`

**Refreshed pages:**
- [[commands/web]]
