# 2026-10-29 — Read-only `hive runtime projects` and `hive runtime payloads`

- hivedev's read-only workspace audit flagged two known gaps. Hive had no
  public read-only way to list registered project paths or runtime payload
  files. `hive status --json` refuses a read-only state root, and
  `status --operational` lists only tasks.
- `hive runtime projects [--json]` lists the global registry entries: name,
  project_id, path, real_path and the resolved hive_state_path. It does not
  load project config and writes nothing.
- `hive runtime payloads [--json]` lists `payload_references` rows with
  kind, state, task/attempt id, relative_path, sha256 and bytes, plus the
  absolute `path` resolved under `Hive::Paths.runtime_payload_root`. The
  read goes through the new `Database#payload_references_snapshot`, which
  uses status's readonly/immutable inspection policy and creates no
  WAL/SHM sidecars. Missing storage reports `phase: "absent"` with an empty
  list and exit 0.
- Both actions are strict no-write routes in `ActivationGate`.
  `hive-runtime-maintenance.v1` gains additive `ProjectsPayload` and
  `PayloadsPayload` branches; schema_version is unchanged.
- Updated [[commands/runtime]] and [[cli]].
