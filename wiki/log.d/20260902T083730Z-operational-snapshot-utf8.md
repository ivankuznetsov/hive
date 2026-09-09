---
title: Normalize valid marker text before operational SQL publication
date: 2026-09-02
tags: [daemon, operational-status, sqlite, utf8]
---

- The runtime-control-plane JSON codec now recognizes valid UTF-8 bytes carried
  by Ruby `ASCII-8BIT` strings as text while continuing to reject malformed
  byte sequences.
- Completed daemon snapshots and their cached `hive-status` graph can therefore
  publish non-ASCII marker diagnostics produced by the binary-safe marker
  reader instead of leaving an expired `tick_started` observation behind.
- Added a full operational publication regression covering both the scheduler
  task row and the stored status projection.
- Scheduler/recovery comparisons now use the same NFC form as persisted JSON,
  so decomposed Unicode cannot create a permanent scheduler-task mismatch.
