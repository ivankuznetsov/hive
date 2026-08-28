---
date: 2026-08-28
slug: fix-publication-rework-authorization
---

- Fixed Patrol Fix publication-policy rework authorization to inspect the
  current receipt rows and return the stage runner's structured rework context,
  rather than treating receipt rows as a store or returning an incompatible
  boolean.
