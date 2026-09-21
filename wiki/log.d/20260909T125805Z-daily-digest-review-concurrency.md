---
title: Close daily digest concurrency and historical-boundary gaps
date: 2026-09-09
tags: [digest, concurrency, membership, cache, archive, coverage]
---

## Daily digest review hardening

- Serialized each refresh's read, collection, merge, and commit under the
  store lock so concurrent refreshes cannot lose facts or regress frontiers.
- Scoped collection and boundary attention to registration membership spans,
  retained cached boundary folds, and made PR publication evidence a journal
  cache dependency.
- Resolved archive links from each task's workflow terminal stage and classified
  pre-coverage dates from the persisted first-interval local label.
