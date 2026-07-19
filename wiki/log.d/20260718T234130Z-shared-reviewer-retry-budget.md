---
title: Share reviewer retry-budget parsing
type: changed
date: 2026-07-18
---

`Hive::Reviewers::Base` now owns the `max_attempts` parser used by the Agent
and native Codex review adapters. Valid values, the default, the defensive
warning for direct/custom construction, retry counts, and backoff behavior are
unchanged.
