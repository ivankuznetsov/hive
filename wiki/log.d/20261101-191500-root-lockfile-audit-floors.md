# 2026-11-01 — Refresh root lockfile audit floors

- Updated root `Gemfile.lock` only: transitive `addressable` now resolves to
  2.9.2 and every locked platform `sqlite3` package to 2.10.2.
- The compatible patch updates satisfy the Addressable URI advisories and
  SQLite GHSA-4fqr-96q8-xrfx reported by the current `bundler-audit` database;
  no declared dependency constraints changed.
