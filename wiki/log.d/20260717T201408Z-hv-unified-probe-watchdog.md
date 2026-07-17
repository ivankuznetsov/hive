---
title: Unified hv version-probe watchdog
type: log
created: 2026-07-17
tags: [hv, install, timeout, process-group]
---

**Action:** Routed every `bin/hv` candidate version probe through the existing
dedicated-process-group watchdog instead of using GNU `timeout` when available.
This preserves the five-second bound when a candidate exits after forking a
stdout-inheriting helper and ensures the helper is swept rather than orphaned.

**Evidence:** `test/unit/hv_test.rb` reproduces the GNU-timeout hang with a
candidate whose direct process exits immediately while its child retains stdout,
then verifies that `hv` falls through to a valid candidate and kills the child.
Pages: [[operating]], [[testing]].
