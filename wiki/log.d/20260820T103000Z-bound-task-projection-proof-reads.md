## Bound task-projection proof reads

Task projection cache validation and journal replay now validate immutable
permanent attempts through a narrow `fetch_projection_binding` read. It checks
the complete proof envelope plus the
exact identity, generation, lineage, lifecycle, outcome, and lease fields used
by the projection without reconstructing receipts or revalidating cumulative
inherited-output arrays. Hot attempt records and ordinary proof fetches retain
full validation.

This removes the global-status hot loop observed with 5,045 task bindings and
205 MB of permanent proof history, where a single 61 MB task took 13.8 seconds
to rebuild full records but 0.6 seconds to parse its immutable binding fields.
