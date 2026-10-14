---
date: 2026-10-02
title: StreamLog tail recovery fails closed before frame publication
tags: [attempts, stream-log, recovery, concurrency]
---

- Replaced best-effort torn-tail sealing, which could swallow a separator I/O
  failure and report success for an unreadable frame, with an append-owned
  fail-closed boundary. The invalidating `"#\n".b` separator must be completely
  written and defensively flushed before sequence allocation; errors escape
  unchanged for caller-controlled, physical-state-driven retry.
- Recovery preserves the damaged bytes while keeping an unconfirmed JSON tail
  unreadable. Per-instance mutex and bounded, monotonic, nonblocking per-log
  advisory-lock acquisition now cover physical inspection, sealing, streaming
  strict sequence reconciliation, and frame publication for cooperating
  threads, instances, and processes. Failed appends invalidate the snapshot for
  the next scan, and unlock exceptions fall back to descriptor replacement.
- Focused StreamLog regressions cover ambiguous separator outcomes,
  same-instance and reopen retry, strict-read and constructor cleanup failures,
  and thread, instance, and process contention. Client and archive regressions
  prove successful post-recovery frames remain cursor-visible, while Supervisor
  coverage pins both one-shot and persistent fatal drain-error outcomes plus
  diagnostic terminalization after one-shot flush and sync failures.
