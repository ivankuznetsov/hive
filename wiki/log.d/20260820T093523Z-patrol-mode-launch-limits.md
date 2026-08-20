# Restore mode-derived Patrol launch limits without token budgets

- Patrol modes now derive one project-wide UTC-day agent-launch allowance:
  ultrapatrol 36, high 18, medium 8, and low 2.
- Ordinary review/fix and Architecture Patrol review/fix share the same count;
  metered and unmetered UsageDb rows each consume one launch.
- Patrol no longer estimates prompt size, configures per-agent token ceilings,
  or uses token totals for admission. Token usage remains telemetry.
- The gate records an unmetered launch reservation before the provider child
  starts, then updates that row with final telemetry. A controller crash still
  consumes the reserved launch.
- Registered project names scope both the counter and its lock, so projects
  with matching checkout basenames retain independent daily allowances.
- Explicit launch overrides require at least two launches, matching low mode,
  so a one-launch configuration cannot permanently starve fix work.
- Daily launch exhaustion is structured as `daily_agent_spawn_limit`; ordinary
  and Architecture Patrol schedulers defer retry until the next UTC day instead
  of repeatedly dispatching work that cannot start.
- `hive migrate` retires former token and specialized quota keys while
  preserving an explicit `max_agent_spawns_per_day` override.
