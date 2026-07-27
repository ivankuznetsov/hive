## [2026-07-27T22:43:13Z] workflow publish — close fail-closed boundary coverage

- Made bounded safe-file reads return empty bytes for zero-byte regular files,
  so empty YAML behavior assets produce the intended malformed-YAML finding
  instead of an internal scanner error.
- Added deterministic tests for cleanup warnings, file-identity races, strict
  permission paths and `x-hive` shapes, retained bundle/object integrity,
  commit-tree drift, and GC-marker failures.
- Removed unreachable I/O rescue branches already normalized by the shared
  safe-file boundary.
