# 2026-11-01 — Refresh audit lockfile security floors

- `bundler-audit --update` began reporting seven Addressable advisories for
  version 2.9.0 and GHSA-4fqr-96q8-xrfx for SQLite3 below 2.10.2.
- Updated both root and packaged-web lockfiles to Addressable 2.9.2 and
  SQLite3 2.10.2. No dependency constraints or application code changed.
- Verified both `bundler-audit` commands against advisory database commit
  `5bcb276b2d95be545a7fc377f9b4515e5fec1915`.
