# Remove unused job action-index reader

- Removed `RefactorPatrol::JobStore#action_index`, which had no production
  caller, together with its now-unreachable generic derived-index reader.
- Kept action projection validation in `rebuild_indexes!` and retained live
  fingerprint-index corruption recovery coverage.
