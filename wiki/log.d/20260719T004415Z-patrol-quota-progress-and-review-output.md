---
title: Keep patrol review progress within launch budgets
date: 2026-07-19
tags: [patrol, refactor-patrol, quotas, review, audit]
---

- Bounded ordinary review batches by the tighter remaining cycle or shared UTC-day launch envelope and reserved one launch for fixing when headroom permits it.
- Advanced a failed batch cursor past its proven-clean prefix while retaining the first failed feature and remaining suffix for retry.
- Accepted a single whole-message JSON fence from read-only architecture reviewers without permitting surrounding prose.
- Bounded architecture review batches by remaining launch headroom, stopped on the first failed slice, and checkpointed clean bounded progress while leaving untouched slices retryable without synthetic failures.
- Backed daily architecture quota failures, including insufficient remaining daily token headroom for another launch, off until the next UTC budget window instead of retrying every minute.
- Preserved every real read-only architecture final response beside the normalized thesis artifact in a durable run directory with job, PR, analysis-SHA, and feature context so failed and successful review quality remains attributable.
