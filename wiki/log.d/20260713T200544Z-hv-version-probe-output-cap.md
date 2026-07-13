---
title: Bound hv version probe output
type: log
created: 2026-07-13
tags: [cli, hv, performance, subprocess]
---

**Action:** Bounded `bin/hv` candidate version probes to one line and 64 bytes. Both the installed-`timeout` path and the portable watchdog path now pipe through a capped reader, reject overflow, and stop an output-flooding candidate instead of buffering its full output in memory or temporary storage.

**Evidence:** `test/unit/hv_test.rb` exercises a candidate that prints a valid-looking first version line and then floods output on both probe implementations, proving `hv` stops it before completion and falls through to the next valid candidate. The full focused test file also preserves timeout, process-group cleanup, recursion-guard, and override coverage.
