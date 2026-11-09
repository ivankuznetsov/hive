# 2026-11-03 — Patch web HTML/XML dependencies flagged by CI

- Updated `web/Gemfile.lock`: Nokogiri 1.19.4 → 1.19.7 across all eight
  platform variants, rails-html-sanitizer 1.7.1 → 1.7.2, and its required
  Loofah dependency 2.25.2 → 2.25.3. Direct dependency constraints are unchanged.
- Reproduced the audit findings against the previous lockfile and verified
  that both current lockfiles pass against a freshly cloned advisory database.
- Frozen web bundle installation succeeded. Existing markdown helper and
  artifact-rendering integration tests passed (4 tests, 38 assertions).
- Updated [[dependencies]] to record the patched web versions.
