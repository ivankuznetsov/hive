# 2026-10-12 — Probe credential keys cannot restore scrubbed runtime keys

- The generation-2 overlay fix closed `request.environment` as an overlay
  channel, but `child_environment` still copied
  `request.credential_environment_keys` from the ambient environment after
  the Ruby/Bundler denylist scrub. A probe request listing `RUBYOPT` (or
  `GEM_HOME`, `GEM_PATH`, `RUBYLIB`, `BUNDLE_*`) as a credential key
  restored the poisoned ambient value into the probe child, re-breaking
  Ruby-based executable overrides and launcher shims.
- `ProbeRequest` and `OpenCodePreparationRequest` now reject credential
  environment keys in the new `SCRUBBED_RUNTIME_ENVIRONMENT_KEYS` constant
  with `ArgumentError`, so neither constructor can select a scrubbed
  runtime injection key back into a child environment.
- Defense in depth: the probe `child_environment` now applies the denylist
  scrub last, after credential selection, executable-override selection,
  and the overlay copy, so no caller-controlled channel can reintroduce a
  scrubbed key even if a request bypasses constructor validation.
- Regression coverage lives in
  `components/agent-cli-runtime/test/opencode_preparation_test.rb`.
