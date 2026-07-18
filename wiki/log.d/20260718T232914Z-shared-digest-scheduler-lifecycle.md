---
title: Share digest scheduler state writes
type: changed
date: 2026-07-18
---

The shipped-task and answer digest schedulers now inherit pending-date
ownership, cancellation, failure backoff, dispatch-envelope construction,
observable state reads, and atomic cursor persistence from
`Hive::Daemon::DigestSchedulerBase`. Their cadence, cursor fields, JSON
content, scheduling decisions, and failure/backoff behavior are unchanged.
