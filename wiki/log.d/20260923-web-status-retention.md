---
date: 2026-09-23
title: Reduce status-cache retention and task request work
---

Routine journal reads retain compact projected data and an explicit record
count instead of raw journal records and the replay working graph. Journal
locking, validation, invalidation, and empty-history admission checks remain
authoritative; bounded workspace history still carries its records.

Web task status projects the selected task with an exact dependency closure.
Reading the published dependency context no longer waits behind a fleet
refresh. Feed initialization is serialized separately from subscriber lifecycle
so pages and the background broadcaster share one feed on concurrent startup.

See [[state-model]], [[commands/web]], and [[gaps]] for behavior and remaining
projection-reuse and live-memory validation limits.
