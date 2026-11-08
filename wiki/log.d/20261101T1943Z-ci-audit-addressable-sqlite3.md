# 2026-11-01 — Patch Addressable and SQLite3 audit findings

- The `bundler-audit` CI gate rejected root Addressable 2.9.0 and SQLite3
  2.10.1 against advisory database commit
  `79c0e052ade15d29d3ecc1e8d4fa59c337a86383`. The web lockfile also carried
  Addressable 2.9.0 and SQLite3 2.9.6, below the same security floors.
- Both lockfiles now resolve Addressable 2.9.2 and SQLite3 2.10.2, preserving
  their platform variants and all other dependency versions. Updated
  [[dependencies]] with the patched versions and advisory rationale.
- Validation: both lockfile audits report no vulnerabilities. Focused gemspec,
  SQLite support, runtime database, contention-budget, and usage database tests
  pass: 113 runs, 576 assertions, no failures, errors, or skips.
