# 2026-08-25 — agent-cli-runtime: one repository-internal conformance suite

## Summary

Patrol finding
`pr-1127-2c7346544a5540c5:centralize-agent-runtime-candidate-conformance`
(generation 1): the release verifier `bin/verify-candidate` hard-coded the
installed candidate's complete provider inventory
(`%i[claude codex pi grok opencode]`) and its own synthetic OpenCode capability
contract (`run --help` / `export --help` flag lines), while the source contract
suite (`test/cli_test.rb`, `test/opencode_contract_test.rb`) independently owned
the same ordered decisions. Two owners for one decision meant the candidate
verifier could silently drift from the source contract.

## Change

- Added `components/agent-cli-runtime/test/support/conformance.rb` as the
  single repository-internal owner of two cross-cutting conformance decisions:
  `Conformance::PROVIDER_NAMES` (ordered built-in provider inventory) and
  `Conformance::OPENCODE_RUN_FLAGS` / `OPENCODE_EXPORT_FLAGS` plus stub-help
  renderers. It lives under `test/support` so the gem never packages it;
  `bin/verify-candidate` requires it from the checkout and the suite loads it
  through `test/test_helper.rb`.
- `bin/verify-candidate` now derives its installed-provider assertion and its
  synthetic OpenCode probe-stub help payloads from the shared suite.
- `test/cli_test.rb`, `test/opencode_contract_test.rb`,
  `test/runtime_test.rb`, `test/probe_test.rb`, and
  `test/opencode_preparation_test.rb` consume the shared constants instead of
  local copies.
- Added `test/conformance_suite_test.rb`: parity between the internal
  declaration and shipped library behavior (`Profiles.names`,
  `OpenCode::Probe::REQUIRED_RUN_FLAGS`, `--sanitize`), stub payload shape,
  and a drift guard asserting no test or the verifier keeps its own copy of
  either decision.

## Validation

- Focused: cli, opencode_contract, conformance_suite, runtime, probe,
  opencode_preparation tests.
- End-to-end: `test/mirror_test.rb` projection builds, installs, and runs
  `bin/verify-candidate` against a standalone tree containing the shared file.
- Full component `bundle exec rake test`: only pre-existing environment failure
  (`runtime_test` grok PATH shim on the development machine), reproduced on a
  clean stash of the branch.

## Notes

Shipped library definitions (`Profiles.names`, `OpenCode::Probe::REQUIRED_RUN_FLAGS`)
remain the public SemVer-governed behavior; the internal suite pins the
repository-level decision and the parity test proves agreement. The gem file
list is unchanged.
