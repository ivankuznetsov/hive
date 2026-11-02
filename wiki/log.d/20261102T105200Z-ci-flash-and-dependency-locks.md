# 2026-11-02 — Repair web confirmation and dependency CI failures

- Restore both lockfiles to the Addressable 2.9.2 and sqlite3 2.10.2 versions
  already on `origin/main`, removing the branch's security-patch downgrades.
  Root and web advisory checks both report no vulnerabilities.
- Reproduce the missing idea acknowledgement with a forced refresh after
  submission. Rails consumes flash on the redirect GET; a later background
  GET renders no notice and previously removed it during morphing.
- Give notices/alerts a stable container and prevent an empty refresh from
  morphing it. The project-rail browser scenario verifies refresh survival,
  replacement by a new submission's message, and clearing on navigation.
- The unmodified browser scenario passed locally with seed 4996. The forced
  refresh regression failed before the fix and passed afterward; the exact
  original CI timing remains unproven locally.
- Validation: the full Rails system suite with CI seed 4996 passed (98 tests,
  1,192 assertions); focused ideas/status integration passed (29 tests,
  289 assertions); usage-store tests passed (32 tests, 144 assertions).
  Root/web advisory checks, focused RuboCop, and `git diff --check` passed.
