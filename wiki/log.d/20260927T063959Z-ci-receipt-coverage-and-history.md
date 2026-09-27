---
title: CI receipt guard coverage and history realignment
date: 2026-09-27
tags: [testing, receipts, web, turbo]
---

Receipt tests now exercise the concurrency, authorization, schema-integrity,
database-recovery, and prune-contention guards required by the exact line
coverage gate. Browser history realignment also reapplies the URL-selected
project after Turbo renders, preventing the permanent composer from retaining
the project selected by the later history entry. Explicit visits clear a
superseded history selection before it can leak into the next render.
