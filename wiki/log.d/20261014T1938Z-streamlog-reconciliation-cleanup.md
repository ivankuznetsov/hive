---
title: StreamLog reconciliation and cleanup parity
type: log
date: 2026-10-14
---

- Strict sequence reconciliation now rejects non-canonical Base64 padding bits
  exactly as public replay does.
- Constructor interrupts release both log descriptors and owned custody without
  masking the initiating unwind.
- Failed append-descriptor replacement keeps remaining resources explicitly
  closeable and closes replacements that fail validation.
