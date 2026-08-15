---
title: Split the remaining coverage long pole
slug: split-remaining-coverage-long-pole
date: 2026-08-14T17:10:00Z
---

**Action:** Split the original fourth source-byte partition into two coverage
collectors. Together with the prior targeted split, CI now has six collectors:
the first two original partitions remain exact, while the two repeatedly slow
original partitions each have two deterministic, source-byte-balanced halves.
Shard zero, raw-result upload/merge, exact 100% enforcement, and protected
aggregate contracts are unchanged.

**Measurement:** The unchanged fourth original collector took 368, 294, and
370 seconds across exact-head runs `31818138021`, `31819264376`, and
`31821818842`. After the first targeted split it became the clear 401-second
job-level critical path. The five-way workflow completed in 469 seconds versus
the 1,592-second baseline median. Six-way exact-head run `31823734367` passed
all 23 jobs in 394 seconds (6m34): 16.0% faster than the five-way run and 75.3%
faster than baseline. The two new collector steps each took 154 seconds, with
172- and 176-second job durations, versus the prior 370-second step and
401-second job. The exact merged 100% coverage gate and protected aggregate
both passed; runner use fell from 43.7 to 43.0 minutes.

**Decision:** Keep the targeted split. It removes 58.4% of the measured
collector long pole without increasing runner minutes or weakening a gate.
