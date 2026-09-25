# 2026-09-25 — `bin/test` no longer signals reaped workers' process groups

- `script/test_parallel.rb` used to send TERM, then KILL, to every worker's
  process group only when the whole run ended, including workers reaped long
  before. Once a reaped worker's group empties, its id is free, and on a busy
  host (PIDs wrap) it can be reused as another program's process group. A long
  local test run therefore SIGTERMed unrelated work: concurrent Hive agents
  died mid-run with `exit_code=-15` and were recorded as lost attempts.
- A reaped worker's group now gets TERM immediately at reap (while any
  survivor still pins the id), KILL once after one second, and is never
  signalled again. Workers still running at cleanup keep the TERM/KILL path.
