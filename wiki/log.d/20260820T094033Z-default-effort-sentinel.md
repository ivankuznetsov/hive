# Default effort is metadata, not a provider CLI value

Legacy explicit-identity launches now preserve `default` and `inherit` as the
requested effort while omitting the native effort flag. Routed launches
already applied that rule, but plan-review reviewers use the explicit identity
path. As a result, a Grok plan review configured with Hive's normal `default`
sentinel previously received `--reasoning-effort default`; Grok rejected the
launch because `default` is not one of its native effort levels.

`Hive::AgentProfile#identity_arguments` now passes no package-level effort for
either sentinel, reports no effective pinned effort, and retains the requested
sentinel in durable launch identity. Concrete effort values continue to render
through the provider's native argument builder.
