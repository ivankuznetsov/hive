# 2026-11-02 — Patch web HTML sanitization dependencies

- Updated only Loofah (2.25.3), Nokogiri (1.19.7), and
  rails-html-sanitizer (1.7.2) in `web/Gemfile.lock`, retaining all existing
  platform variants and unrelated dependency locks.
- The web lockfile audit reproduced the CI failure before the update and
  reports no vulnerabilities after the update.
- Root and web audits pass against a freshly downloaded advisory database;
  the existing Rails Markdown helper tests pass (3 tests, 19 assertions).
