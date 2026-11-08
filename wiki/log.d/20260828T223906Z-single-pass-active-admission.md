# 2026-08-28 — Reuse active status classification for admission

## Summary

The routine active-status producer now action-classifies each candidate task
once and derives dependency admission from those prepared rows. It no longer
rereads every active folder through a separate terminal-classification pass.
The public `hive-status.v7` payload and archive behavior are unchanged.

## Details

- Status captures workflow generations, prepares every project row, and then
  passes the selected active folders into `DependencySnapshot`.
- Referenced archived prerequisites are still loaded exactly and recursively,
  so completed dependencies retain their admission semantics without restoring
  a fleet-wide history scan.
- A project that cannot produce its active rows falls back to the previous
  per-project disk admission scan; if that scan also fails, admission remains
  fail-closed without dropping healthy projects from the status envelope.
- Completion failures remain isolated to one degraded project, and synthetic
  rows retain captured archive membership without consulting mutable global
  workflow state after preparation.
- `Tui::StateSource` publishes the payload and admission context returned by
  one active projection result instead of building a second context.
- A regression counts `TaskAction` calls for active and archived candidates in
  a terminal-capable stage and requires exactly one classification apiece.

On a live 245-row registry, repeated same-process comparisons reduced routine
payload construction by 26 to 31 percent. The final run took 8.31 seconds on
the old path and 6.15 seconds on the reused-row path, whose fixed-time payload
was byte-for-byte equal to the immediately preceding old-path payload. The
remaining rich v7 serialization cost is intentionally left for a separate
consumer-contract change.

## Refreshed pages

- [[commands/status]]
- [[commands/web]]
- [[modules/daemon]]
- [[testing]]
