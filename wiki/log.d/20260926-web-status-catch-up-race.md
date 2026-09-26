# 2026-09-26 — Status-stream system tests keep the source attached until catch-up

- Two `StatusStreamSourceTest` recovery tests removed their temporary
  `hive-status-stream-source` host in the page script's `finally` as soon as it
  connected. The source's catch-up request could still be in flight, so the
  server never recorded a catch-up for the page token and
  `wait_for_status_catch_up` timed out (`Timeout::Error`) intermittently in the
  `Hive web system tests` CI job.
- A connected host now stays attached (`window.__hiveCatchUpHost`) until Ruby
  observes the catch-up; the test's `ensure` removes it.
