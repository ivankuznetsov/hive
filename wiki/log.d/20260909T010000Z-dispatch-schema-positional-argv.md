# 2026-09-09 — Dispatch request schemas enforce positional argv allowlist

## Summary

`schemas/hive-dispatch-request.v4.json` and `hive-dispatch-request.v5.json`
constrained `argv` only to "array of ≥2 non-empty strings", so a payload with
`argv: ["curl", "anything"]` passed external schema validation while the
writer guard `Hive::RuntimeControlPlane::DispatchRepository.valid_argv?`
would raise `ArgumentError`. Both published schemas now encode the guard's
positional contract with draft-2020-12 `prefixItems`:

- `argv[0]` must be the constant `"hive"`.
- `argv[1]` must be in the closed verb enum (`ALLOWED_VERBS` plus
  `"evidence"`).
- `argv[1] == "daemon"` requires the exact global-maintenance argv
  `["hive", "daemon", "install", "--force"]` (`GLOBAL_MAINTENANCE_ARGVS`).
- `argv[1] == "evidence"` requires ≥3 items with
  `argv[2] == "rework"` (`EVIDENCE_VERBS`).

The historical v1–v3 schema files cited by the originating finding were
removed in the 2026-08-29 fleet cutover; the same root cause persisted in
the owned v4/v5 files. The queue class referenced by the finding
(`lib/hive/daemon/dispatch_request_queue.rb`) now lives at
`lib/hive/runtime_control_plane/dispatch_repository.rb`.

`SchemaFilesTest#test_dispatch_request_schemas_enforce_positional_argv_allowlist`
regression-tests the schema behavior and asserts the schema verb enum stays
in lockstep with `ALLOWED_VERBS` / `EVIDENCE_VERBS`. The stale
`$defs.ALLOWED_VERBS` lockstep reference in ADR-029 (wiki/decisions.md) was
updated to point at the positional `argv` constraint.
