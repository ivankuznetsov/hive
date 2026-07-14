---
title: Bound hv probes that ignore TERM
type: log
created: 2026-07-14
tags: [hv, cli, timeout, watchdog]
---

**Action:** Added a one-second KILL escalation to `bin/hv`'s installed-`timeout` version-probe path. A stale or wrapper candidate that ignores the five-second TERM can no longer keep `hv` from trying later candidates indefinitely.

**Evidence:** `test/unit/hv_test.rb` supplies a fake external `timeout` and a candidate that ignores TERM, then verifies that `hv` kills it and launches the next valid candidate. The existing no-`timeout` watchdog coverage remains unchanged.
