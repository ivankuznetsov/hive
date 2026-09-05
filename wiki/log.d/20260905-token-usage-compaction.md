---
title: Retain token totals without permanent per-run rows
type: change
date: 2026-09-05
---

Added `token_usage_daily` beside recent `token_usage` detail. Hourly maintenance
atomically rolls up and removes at most 500 settled rows older than seven UTC
days. Summary days fence late replay; unfinished sessions and unacknowledged
attempt accounting remain detailed. No compaction ledger, outbox, checkpoint,
or additional worker was introduced.

Task summaries now query raw plus daily usage directly instead of treating a
bounded attempt/journal inventory as an accounting authority. Web exposes
stage/provider/model totals and explains per-run expiry. Unknown metric flags
and provider-reported costs survive aggregation. API-equivalent estimates
remain detail-dependent; expired detail is unpriced, not repriced or zero.
The 30-day aggregate uses a UTC-day boundary; the seven-day window stays rolling.

Tests cover atomic rollback, restart/replay, competing compactors, late first
receipts, unsettled accounting, retention boundaries, model grouping, unknown
counts, direct task totals and web rendering. This is an unreleased base-schema
change requiring a separately authorized offline dogfood cutover. Live usage
has not been compacted by this implementation work.
