# 2026-11-03 — Patch the web HTML sanitization dependencies

- Reproduced the web lockfile audit failures for Loofah 2.25.2, Nokogiri
  1.19.4, and rails-html-sanitizer 1.7.1. The truncated CI log omitted the
  Loofah findings.
- Updated only those three transitive gems with a conservative patch
  resolution: Loofah 2.25.3, Nokogiri 1.19.7 on all existing platforms, and
  rails-html-sanitizer 1.7.2. Bundler also records their updated transitive
  minimum versions; direct Gemfile constraints are unchanged.
- Both root and web lockfile audits report no vulnerabilities against the
  refreshed advisory database.
