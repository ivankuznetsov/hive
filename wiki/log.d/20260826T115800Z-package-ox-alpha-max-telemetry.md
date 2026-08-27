# Package Ox Alpha max and OpenCode telemetry recovery

- Synchronized the proven Ox Alpha Pi/OpenCode generation runtime into the
  built-in benchmark snapshot without replacing Hive's newer judge retry and
  deliberation validation files.
- Added a separate Pi-only `all-ox-alpha@max` candidate with explicit max routes
  for plan, execute, and review. High Pi and high OpenCode remain separate rows,
  and all preserve the benchmark-only plan-review opt-out.
- Added the pinned OpenCode runner, Compound Engineering inventory gate, Pi
  OpenRouter catalog, and bounded execute/review recovery helpers used by the
  completed high campaigns.
- OpenCode token extraction now falls back to the cell-local Hive usage database
  when its intentionally redacted stage logs contain no token events. Focused
  built-in workflow coverage executes both the max routing and database paths.
- Closed a candidate-contamination boundary exposed by the Ox Alpha log audit:
  candidate repos now contain only a depth-one fetch of the historical base,
  and strict campaigns require an internal Docker network plus provider-only
  CONNECT proxy. Both isolation modes are recorded in generation identity.
