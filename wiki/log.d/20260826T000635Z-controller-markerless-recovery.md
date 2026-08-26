# Controller markerless recovery preserves structured state

- Controller workflows no longer receive inline `ERROR` markers when a stage
  exits without advancing its durable projection; Patrol Fix manifests remain
  valid JSON.
- The healer now records one generation-bound `markerless_failure` request in
  the existing recovery queue. The request survives restart, follows the shared
  retry ladder, and rearms the same identity after an unchanged failed retry.
- Recovery queue validation and the published v5 schema cover the new variant,
  including its prohibition on marker, routing-policy, and provider-route
  evidence.
