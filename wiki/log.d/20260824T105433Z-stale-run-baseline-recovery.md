# Recover replaced generic workflow state from stale dispatch baselines

## [2026-08-24T10:54:33Z] daemon — admit an older replacement state file once

- Changed generic `ready_to_run` dispatch so a current state-file mtime older
  than a `[project, slug]` baseline loaded from the persisted store is treated
  as a replaced or restored state file, not as a markerless agent exit.
- Gated recovery on the controller's existing restored-baseline provenance.
  A same-process refresh from a newer sibling artifact therefore cannot create
  a redispatch loop merely because its timestamp is newer than the state file.
- Durable attempt acceptance now consumes the observed mtime immediately,
  matching local child dispatch and preventing repeated admission checks;
  terminal replay remains the restart-safe fallback.
- Kept all same-process older/equal mtimes on the existing
  `markerless_stalled` brake, so unchanged markerless stages cannot redispatch
  every daemon tick.
- Added focused policy and dispatcher regressions for local and durable
  dispatch paths. This unstrands the migrated Patrol Fix manifests whose
  persisted baselines were newer than their current workflow state.
