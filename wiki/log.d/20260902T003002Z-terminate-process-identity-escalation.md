---
title: Preserve process identity through TERM-to-KILL escalation
date: 2026-09-02
tags: [process-cleanup, pid-reuse, drop, safety]
---

- Made single-PID cleanup retain one `match`, `replacement`, or `unavailable`
  start-identity decision after each failed grace wait. A readable replacement
  now suppresses KILL and completes the recorded cleanup; unavailable identity
  fails closed when one liveness check still finds the PID live.
- Preserved compatibility at both boundaries: an unavailable initial lookup
  may still authorize TERM, records without a start time keep liveness-only
  TERM-to-KILL escalation, and `terminate_process_group` keeps its existing
  initial ownership and confirmed-tree behavior.
- Made any Drop `kill_failed` result fence task-lease acquisition, destructive
  cleanup, and the audit commit. Task identity, PR state, worktree, branch,
  folders, and logs remain available for remediation and an ordinary retry;
  mixed-candidate success cannot hide the refusal.
- Added deterministic exact-read/exact-signal coverage for post-TERM and
  post-KILL replacement, unavailable/absent, unavailable/live, matching,
  retry, no-start-time, permission, and process-group compatibility paths,
  plus Drop preservation and v2 aggregation coverage.
- Kept `agent_killed_pids` as compatibility audit context even when the
  recorded number now names a live replacement. It is not a signalling list;
  pidfds, cgroups, process handles, and other durable containment remain out of
  scope.
