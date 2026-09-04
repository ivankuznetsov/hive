---
title: Remove unused runtime columns
date: 2026-09-04
---

Removed unused task-lease generation, source fingerprint, kind, and timestamp
columns. Ownership still uses nonce/version compare-and-swap and PID/start-time
liveness. Removed the duplicate installation lineage identity from SQL and
cutover manifests, retaining installation identity and activation epoch checks.
Dropped the write-only project repository identity JSON copy.

The daemon publishes one observation document per installation, without a
second copy of its state, generation, process identity, or timestamps in SQL
columns. Document freshness and status-projection binding checks remain.
The unreleased schema is rewritten in place; existing-schema opens continue
to reject mismatched databases. No deployed database was changed.
