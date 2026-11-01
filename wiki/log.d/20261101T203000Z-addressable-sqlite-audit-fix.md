# 2026-11-01 — Patch Addressable and sqlite3 audit failures

- Relocked only `addressable` and `sqlite3` in the root and web bundles to
  2.9.2 and 2.10.2 respectively, preserving dependency constraints and locked
  platforms. These versions clear the October 2026 Addressable advisories
  and sqlite3 GHSA-4fqr-96q8-xrfx.
- Reproduced the audit failure using the original root lockfile, then audited
  both updated lockfiles successfully against advisory database commit
  `79c0e052ade15d29d3ecc1e8d4fa59c337a86383`.
- Existing runtime database, usage database, and gemspec tests passed:
  100 runs, 495 assertions. Updated [[dependencies]] and recorded validation
  limits in [[gaps]].
