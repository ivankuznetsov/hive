# Explicit fix-guardrail detector strategy per pattern descriptor

Date: 2026-08-25
Scope: `lib/hive/stages/review/fix_guardrail.rb`, `lib/hive/stages/review/fix_guardrail/patterns.rb`

## What changed

Every `FixGuardrail::Patterns` descriptor now declares an explicit
`:detector` key — `:regex` (spec's own regex matched against the target
text) or `:secret_patterns` (dispatch to `Hive::SecretPatterns.scan`).
`scan_diff` dispatches on that key instead of branching on the pattern
name (`if name == :secrets_pattern_match`), and an unknown detector
value raises instead of silently no-op-ing. `normalize_custom_pattern`
stamps Hash overrides with `detector: :regex`, so replacement semantics
are total: a Hash override under any name — including
`secrets_pattern_match` — always installs a plain regex detector and
the SecretPatterns dispatch never survives an override.

## Why

Architecture patrol finding
`pr-1148-29a3b5c29236f8c9:make-fix-guardrail-detector-dispatch-explicit`:
scanner behavior was coupled to a magic registry key while the
descriptor's own regex stayed nil, so the override boundary could
replace the special name with a normalized regex descriptor that scan
still bypassed in favor of SecretPatterns.

## Tests

- `test_every_default_pattern_declares_an_explicit_detector`
- `test_hash_override_of_secrets_pattern_match_replaces_the_special_detector`
  (AWS key alone no longer trips after a Hash override)
- `test_hash_override_of_secrets_pattern_match_matches_via_its_own_regex`

`wiki/stages/review.md` documents the detector key and the total
replacement semantics.
