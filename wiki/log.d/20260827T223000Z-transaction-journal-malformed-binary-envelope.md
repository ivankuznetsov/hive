---
title: Fail closed on malformed binary journal envelopes
type: fix
date: 2026-08-27
tags: [workflow-package, transaction-journal, binary, validation]
---

`Hive::WorkflowPackage::TransactionJournal` now translates invalid base64 and
non-string `__binary__` marker values into the journal's existing malformed
`Hive::ConfigError`. A syntactically valid but corrupt journal can no longer
escape reconciliation as an untyped `ArgumentError` or `TypeError`.

Regression tests cover both corrupt envelope shapes as well as the existing
valid binary round trip.
