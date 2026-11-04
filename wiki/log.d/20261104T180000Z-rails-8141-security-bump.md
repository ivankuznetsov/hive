# 2026-11-04 — Rails frameworks 8.1.4.1 for the Active Support advisories

- `bundler-audit` failed on main for the 2026-11-04 Active Support advisories
  GHSA-2w9f-fxwj-w2qf and GHSA-8474-xrp6-wh69, which need `>= 8.1.4.1`.
- The root `Gemfile.lock` (transitive `activesupport`) moved from 8.1.3 to
  8.1.4.1. `web/Gemfile.lock` moved every Rails framework gem from 8.1.3.1
  to 8.1.4.1 using `bundle update --conservative`. The `web/Gemfile`
  constraint `~> 8.1.3` is unchanged, and no other gem moved.
- Neither lockfile records CHECKSUMS, and no other manifest in the repo pins
  Rails gem versions.
