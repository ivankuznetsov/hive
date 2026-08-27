# Bench hands preserved candidate patches to judge

**Change:** The built-in bench generate stage now accepts a clean per-cell
result with a preserved non-empty `candidate.patch` as sufficient input for
the judge stage, while retaining the cell's honest generation status. It
merges the campaign-root `results.json` and lets judge backfill the configured
slate without buying the candidate again.

**Why:** Generate already refused to regenerate these paid diffs and reported
them as `judges_pending`, but it also withheld the campaign-root result that
judge requires. That left OpenCode and Pi cells with recoverable patches in a
permanent generate-stage `WAITING` loop.

**Guard:** Missing cells, zero-byte patches, non-empty pending/failed buckets,
malformed results, and contradictory terminal results retain their existing
WAITING or quota-retry classification.
