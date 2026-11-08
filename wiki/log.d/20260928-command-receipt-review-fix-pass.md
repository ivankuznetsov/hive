---
date: 2026-09-28
title: Bound command receipt replay and maintenance review paths
---

- Separate namespace and installation reclamation cursors, maintain bounded
  installation capacity aggregates, and cap completed-batch cleanup.
- Resolve mutable maintenance authority before SQLite writer transactions and
  reauthorize resumed prune batches from that current snapshot.
- Preserve typed results across display-mode changes, expose permanent applied
  result loss as a closed command reason, and translate post-effect persistence
  loss to `COMMAND_UNRESOLVED`.
- Detect foreground web writers during extension installation, validate the
  extension version ledger on ordinary database open, and keep setup opt-in
  explicit even under `--yes`.
- Expand boundary coverage for raw token/key persistence, move-and-replay,
  pruning limits and cutoff, pin horizons, non-owner disclosure, and storage
  exhaustion.
