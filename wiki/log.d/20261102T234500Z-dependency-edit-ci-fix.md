## [2026-11-02T23:45:00Z] Close dependency edit CI failures

Added rejection assertions for missing/conflicting dependency edit options and
merge/complex YAML keys. The existing dependency edit unit suite now exercises
all 101 executable lines, including the two lines missed by the CI coverage gate.

Updated the web lockfile to Nokogiri 1.19.7, rails-html-sanitizer 1.7.2 and its
required Loofah 2.25.3 patch. Both lockfiles pass bundler-audit against a fresh
advisory database. The focused dependency suites pass (89 tests, 356 assertions),
as do Rails markdown rendering and sanitization checks (3 tests, 33 assertions).
No production dependency editing behavior changed; the activity-binding gap
in `wiki/gaps.md` remains.
