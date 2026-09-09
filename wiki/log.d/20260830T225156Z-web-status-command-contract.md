# Authoritative web status command contract

- Introduced `Hive::Web::StatusCommand`, the single authoritative internal
  contract between `Web::StatusFeed` and the status producer it polls:
  `json_payload` (the bounded scan seam) plus optional
  `dependency_context_snapshot` and `operational_recoveries` members whose
  contract defaults return nil.
- `CachedStatusCommand` includes the contract and calls its `StateSource`
  dependency directly (the source always defines the snapshot reader).
- `StatusFeed#dependency_context_snapshot` and the recovery overlay no longer
  branch on collaborator shape with `respond_to?`; a producer without an
  optional capability returns nil and the feed renders the plain projection.
  The overlay's existing failure fallback (warn + base status) is unchanged.
- Test doubles injected as `status_command` (including the archive-retention
  `FixedStatus`) now declare the contract; regression tests pin no-probing
  behavior and the nil-default degradation path.
