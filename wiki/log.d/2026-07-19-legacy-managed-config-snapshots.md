## Legacy managed-workflow tasks keep resolvable project configuration

- Legacy lock-schema-v1 configuration derivation now uses the effective project
  agent profile overrides instead of the shipped-profile defaults.
- Task creation materializes the derived digest-addressed snapshot before
  writing its configuration pin, so a later schema-v2 workflow update cannot
  strand the task on a digest that exists only in memory.
- Update and same-generation install comparisons use the same project-aware
  legacy derivation, while old task snapshots remain retained until their final
  task reference is removed.
