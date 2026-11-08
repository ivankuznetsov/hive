# 2026-10-12 — Probe request environments are restricted to overlay keys

- The OpenCode probe's child environment was built with
  `selected.merge(request.environment)` after the denylist cleanup, so a
  caller-supplied `RUBYOPT` (or `GEM_HOME`, `GEM_PATH`, `RUBYLIB`,
  `BUNDLE_*`) key survived into the probe child and broke Ruby-based
  executable overrides or launcher shims that the cleanup was supposed to
  protect.
- `ProbeRequest` now validates its `environment:` keys against
  `OPENCODE_OVERLAY_ENVIRONMENT_KEYS` and raises `ArgumentError` for anything
  else. This is a public contract change: constructing a probe request with
  non-overlay environment keys that previously passed silently now fails
  fast.
- As defense in depth, the probe child environment copies only
  overlay-contract keys from the request instead of merging the whole
  request environment, so the Ruby/Bundler injection scrub stays final even
  if a request bypasses validation.
- Regression coverage lives in
  `components/agent-cli-runtime/test/opencode_preparation_test.rb`.
