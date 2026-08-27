---
title: Make markerless recovery rearm return to pending atomically
type: fix
date: 2026-08-27
tags: [daemon, recovery, dispatch-queue, markerless]
---

Terminal markerless recovery retries now atomically release their completed
delivery claim before becoming `admitted`. This prevents the queue body from
being admitted while its filename and claim sidecar still point at the prior
terminal attempt, which previously made reconciliation report the same failed
completion on every daemon tick and kept the retry invisible to pending work.

Startup claim recovery repairs already-persisted `admitted` + claimed records
by returning them to pending instead of deleting them or following their stale
attempt correlation. Terminal delivery reconciliation also requires a durable
terminal transition before writing a result, acknowledging finalization, or
logging `dispatch_request_completed`; conflicts receive their own typed event.
