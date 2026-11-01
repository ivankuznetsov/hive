# 2026-11-01 — Refresh web lockfile audit floors

- Updated `web/Gemfile.lock` only for the current audit findings: transitive
  `addressable` resolves to 2.9.2 and each platform-specific `sqlite3` package
  resolves to 2.10.2.
- The compatible lockfile updates meet the active web `bundler-audit` advisory
  floors without changing any declared web dependency range.
