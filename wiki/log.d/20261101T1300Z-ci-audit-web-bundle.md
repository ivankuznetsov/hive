# 2026-11-01 — CI audits the web bundle

- The `bundler-audit` CI job checked only the root `Gemfile.lock`. The Rails
  app's `web/Gemfile.lock` carried crass 1.0.7 and mail 2.9.0 advisories that
  CI never reported (patched by hand in #1576). The job now also runs
  `bundler-audit check --gemfile-lock web/Gemfile.lock` against the advisory
  database the first step updated.
