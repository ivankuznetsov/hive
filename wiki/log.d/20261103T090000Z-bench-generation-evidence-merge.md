# Isolate generation replacement and rejudging evidence

Merge selects generation snapshots in explicit oldest-to-newest input order.
A replacement discards prior judges, gates and telemetry from the active cell;
verified judge-only overlays retain evidence only for the same bound generation
and evaluation context. Conflicting bindings invalidate admission. Discarded
snapshots remain deduplicated in top-level `generation_history`.

Rejudge resolves patch and plan from one verified artifact bundle, preserves
non-cell document metadata, and adopts selected legacy artifacts without
regeneration. Old unbound judges require fresh judging; an unbound gate remains
excluded with `fresh gating required`. Repeated merges and backfills preserve
attempt costs without double charging identical parked snapshots.
