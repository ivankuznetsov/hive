---
title: Preserve scheduler observations for providerless daemon rows
date: 2026-09-13
---

Live dogfood recovery exposed a `NameError` in digest hold observation when a
capacity-held daemon row had no provider member. Treat the missing optional
Struct field as absent, and exercise the actual `StatusConsumer::Row` in the
hold entry/exit tests instead of a test-only row with an invented member.
See [[modules/daily-digest]].
