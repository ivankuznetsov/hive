---
title: Share PATH executable lookup
type: changed
date: 2026-07-19
---

Doctor, update, and service installation now delegate their PATH-only
executable lookup to `Hive::InvokedBinary.which`. Their private test seams,
injected update environment, lookup order, executable checks, and nil fallbacks
are unchanged. Babysitter dry-run keeps its distinct realpath-resolving lookup.
