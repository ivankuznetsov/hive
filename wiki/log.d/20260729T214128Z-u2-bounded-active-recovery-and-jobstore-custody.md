---
date: 2026-07-29
area: patrol, refactor-patrol, migration, storage
---

# Bound active recovery and confine v3 JobStore custody

- Added one descriptor-confined, 4,096-id active occurrence recovery index.
  Reservation, retirement, and dirty-generation fencing cover every crash
  window; missing, malformed, stale, or dirty state receives one bounded
  authoritative repair, while idle ticks never scan retained terminal history.
- Routed live v3 jobs, query-index sidecars, quarantine evidence, and action
  locks through one `JobStoreFiles` port backed by `ManagedDirectory`.
- Enforced the 8,192-job limit under a store-wide admission lock before a new
  per-job lock or query membership can exist. Inventory overflow now stops
  while streaming at the bound instead of materializing arbitrary entries.
- Established native-v3 admission before architecture recovery backoff/index
  repair writes, and made semantic-family dry-run authority reads use a
  read-only JobStore so previews remain state-free.
