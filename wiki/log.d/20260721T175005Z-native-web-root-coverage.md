## [2026-07-21T17:50:05Z] native web — restore root coverage proof

- Added root-suite behavioral coverage for loopback host authorization so the
  production Rails contract also participates in the repository's 100% line
  gate.
- Pinned authenticated `Gemfile.lock` byte/mode restoration across both
  Bundler and asset compilation, plus successful and escalated bounded verifier
  process cleanup.
- Covered setup's safe observed-service fallback and readiness polling that
  stops when an initially enabled service becomes disabled.
- Focused coverage reports 100% for setup, app bundle, host authorization, and
  service status; the production coverage threshold remains unchanged.
