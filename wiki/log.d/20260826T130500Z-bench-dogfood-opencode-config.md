# Validate benchmark dogfood and OpenCode runtime configuration

- Removed the retired `agents.opencode.isolation` field from benchmark-generated
  configs; containment remains the runner container plus provider-only network.
- Added an end-to-end config regression through `Hive::Config.load` while
  retaining the scoped `Bash(*)` parity grant and Compound Engineering plugin.
- Resolve a dogfood wrapper to the exact deployment id and build SHA inherited
  from its launch, then mount that immutable runtime into candidate cells.
