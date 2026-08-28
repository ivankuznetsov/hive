# Setup emits its envelope even when the global `web` config block is malformed

Date: 2026-07-23
Area: `lib/hive/commands/setup.rb`

## Problem

`Setup#call` resolves the web URL directly (`web_url` → `Config.load_global_web`)
in `add_web_phase` and again in `emit` (and on the consent-refusal path), not
through the `phase(name)` wrapper that converts raises into failed-phase
records. A malformed global `web` block — e.g. `web: "x"` in the global
`config.yml`, which `load_global_web` rejects with `Hive::ConfigError` — aborted
`hive setup` with a raw backtrace before `emit`, so `--json` produced no
envelope at all and automation branching on it (AE5) saw nothing.

## Fix

`web_config` now resolves once, remembers any `Hive::ConfigError`, and falls
back to `Config.global_web_defaults` so every URL lookup stays resolvable. The
remembered error fails the `web` phase (`ok:false`, message on the phase) via
`add_web_phase`, so `ok:false` + exit 1 still hold while the envelope is always
emitted. Managed web-service install is blocked (observation only) when the
config is broken rather than mutating against fabricated defaults.

## Tests

- `test/unit/commands/setup/orchestrator_test.rb`:
  - `test_broken_global_web_config_still_emits_json_and_fails_the_run`
  - `test_broken_global_web_config_still_emits_in_diagnose_only_mode`

## Uncertainty

Whether other commands that call `load_global_web` (`hive web *`) should adopt
the same tolerate-and-report behavior is out of scope for this fix; they are
expected to fail loudly on invalid operator config.
