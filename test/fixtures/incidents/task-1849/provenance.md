# Provenance

This bundle is derived from the repository's durable-attempt 1849 replay and
the legacy `EXECUTE_WAITING reason=no_worktree_changes` incident shape. Paths,
identifiers, timestamps, and commit SHAs are sanitized.

The legacy marker and log excerpts are sanitized source observations. The
condition-era records did not exist in the original runtime; every such record
is declared in `manifest.json` and carries `provenance.synthetic: true` with
`source: incident_reconstruction`.
