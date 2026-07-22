## 2026-07-18 — Share recursive string-key normalization

- Added `Hive::StringifyKeys` as the single owner of the identical recursive
  hash-key normalization used by task journals, task conditions, and Screenote
  credentials.
- Preserved array recursion, scalar values, and non-mutating container copies;
  shallow validators and JSON canonicalizers with different contracts remain
  local.
- Verified every migrated consumer together: 42 runs, 184 assertions, zero
  failures, zero errors, and zero skips.
