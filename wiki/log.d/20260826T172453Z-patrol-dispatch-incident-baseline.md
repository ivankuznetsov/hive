---
title: Freeze the Patrol dispatch incident baseline
type: testing
date: 2026-08-26
tags: [patrol-fix, attempts, incident-replay, capacity]
---

Added a sanitized, deterministic replay of the August 26 daily-cap incident.
The fixture preserves all 600 charged attempts, 598 Patrol Fix and two coding
attempts, 153 failures and 447 successes, the 459 generation-stage identities
and their repeat distribution, and all nine observed failure cohorts. Raw
provider output, task identities, prompts, secret material, credentials, and
host paths are excluded.

The replay separately stores pre-normalization terminal envelopes and expected
normalized codes, pins existing unstarted and TEMPFAIL refunds, preserves
later-stage ordering, and records current starvation at cap 600 as an expected
future-containment failure. Portable metadata retains the temporary 1,000 cap,
the 600 rollback target, and the final soak/UTC-window exit gate. No production
scheduling or recovery behavior changes in this characterization unit.

Seven-day non-Patrol demand remains unknown because retained historical
attempts do not unambiguously identify the workflow for every `1-inbox`
record. The fixture records that uncertainty and the 10% fail-safe instead of
inventing a demand series.
