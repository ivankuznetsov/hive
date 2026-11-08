---
date: 2026-09-27
title: Durable callers share receipt pin and successor lifecycle
---

- Bot, foreground Attempts, and Daemon dispatch now acquire or reacquire the
  same receipt pin from authenticated command context before keyed delivery.
- Their successor requests all use the store-side per-cycle allocator, so
  concurrent handlers and failed-successor redelivery reuse one binding.
- Successor reservation verifies the frozen request fingerprint before binding
  the allocated key identity to a new receipt.
