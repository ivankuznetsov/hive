---
title: Remove unused evidence receipt lookup
date: 2026-08-13
---

- Removed the uncalled
  `Hive::Modules::Migration::EvidenceStore#fetch_receipt` single-record lookup.
  Patrol migration adapters continue to read durable receipt evidence through
  the indexed `receipts_for_occurrence` API, while collection and index tests
  retain restart, validation, and no-follow coverage.
