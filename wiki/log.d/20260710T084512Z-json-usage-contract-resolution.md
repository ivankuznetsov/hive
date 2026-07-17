---
title: Variant-aware pre-dispatch JSON usage contracts
type: log
created: 2026-07-10
tags: [cli, json, schemas, thor, argv]
---

**Action:** Replaced the wrapper's command-only JSON usage lookup with
variant-aware resolution for status/diagnose, web status/install, pairing
list/approve, and shipped/merged-PR digest output. Added the previously omitted
status, prune, forget, and metrics contracts while preserving the established
whole-bot `hive-bot-status` usage-error schema. The positional resolver consumes
known option values and fails closed on an invalid command token, preventing a
later argument from impersonating a command or subcommand. Forget's closed
error-kind enum now distinguishes wrapper-level `usage` from `internal` faults.
The resolver also stops option interpretation at `--`, so later flag-looking
positionals cannot switch the status or digest schema.

**Evidence:** `test/integration/cli_usage_error_json_test.rb` now drives the
real `bin/hive` subprocess through Thor extra-positional failures and the
pre-Thor invalid-encoding guard, parses every stdout envelope, and validates
registered surfaces against their published JSON schemas. Legacy web JSON
envelopes remain unversioned to match their successful output. Collision cases
cover web option values, later pairing arguments, invalid digest source values,
and invalid command-position bytes.
