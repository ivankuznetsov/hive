## Raise the sqlite3 security floor

**Action:** Updated the root and packaged-web lockfiles from `sqlite3` 2.9.5
to 2.9.6 after `bundler-audit --update` began flagging
GHSA-mwm8-39rw-8826. The gemspec and web dependency ranges remain compatible
with the patched release. Also aligned the packaged-web `json` lock with the
existing 2.21.2 security floor for CVE-2026-71847.

**Refreshed pages:** [[dependencies]]
