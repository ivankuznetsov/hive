## 2026-06-10 — hivebox web tier rewritten as a vanilla Rails 8 + Turbo app

The Sinatra/Puma web UI (and its SSE limiter + hand-rolled reconciliation
JS) is replaced by a `rails new` app in `web/`: Turbo Streams over
solid_cable for live status, Stimulus composer with image attach (clipboard
paste + upload button → `[imageN]` + `assets/`, the TUI contract), repos
page listing the operator's GitHub repositories via the retained
device-flow token (scope `repo`), claude.com-style design system, readable
typed-error pages, and a Force-approve gate action. `hive web` now execs
`bin/rails server` (HIVEBOX_WEB_APP_DIR / `web/`), with SECRET_KEY_BASE
derived from the persisted session secret and solid-stack sqlite under
state_home on `/data`. Sinatra, rack-protection, and puma left the gemspec;
the Sinatra-layer tests were replaced by Rails integration tests plus
Capybara + Playwright system tests (CI `web` job). Recorded as ADR-037;
device flow (ADR-036) unchanged. See [[commands/web]].
