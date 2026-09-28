---
date: 2026-09-27
title: Receipt capacity is qualified against finalization and settlement
---

- A reproducible benchmark measures authoritative observation lookup, preview,
  confirmed retirement, maximum-result finalization, and a 100-row prune.
- The measured maximum finalization physical delta is 480,752 bytes, so the
  conservative next-operation allowance is now 512 KiB.
- A real SQLite `max_page_count` exhaustion test proves finalization reports no
  false success and succeeds after capacity is restored.
