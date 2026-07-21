## 2026-07-21 — Add non-binding managed mapping recommendations

- Registry `x-hive` metadata may now declare a sorted, unique
  `mapping_recommendations` array for known executable slots. Entries contain
  only `slot` and an optional portable `low`, `medium`, or `high` effort; agent,
  model, unknown fields, terminal slots, duplicates, and unsorted entries fail
  validation.
- Managed configuration resolves each effort through explicit install override,
  compatible prior installed mapping, package recommendation, then project
  default. Profiles that cannot pin a recommended effort remain explicitly
  unpinned, while explicit unsupported pins still fail closed.
- Interactive install now displays pinned and unpinned model/effort values,
  recomputes those suggestions after an agent change, and lets `unpinned`
  explicitly clear either pin. Web preview and apply use
  the same immutable configuration digest, and manifests without recommendations
  retain their existing configuration bytes.
- Added focused validator, configuration, interactive lifecycle, update-retention,
  and real immutable-registry preview/apply coverage.
