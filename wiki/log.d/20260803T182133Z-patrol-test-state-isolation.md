---
title: Isolate Patrol PR-opener test state
date: 2026-08-03
tags: [testing, patrol, state, recovery]
---

Patrol PR-opener tests now construct and reserve occurrences only under
disposable project roots. The shared test helper rejects the live repository
root before any state write, preventing unit tests from placing synthetic
captures in the daemon's recovery store.
