# One retry ladder paces every retry

Recovery used to pace every automatic retry by one flat window,
`Hive::AgentLimit.retry_cooldown_sec`. A first transient failure and a
tenth consecutive one waited the same hour, and the provider window was a
second, separate concept that could disagree with the marker window.

`Hive::Daemon::RecoveryCoordinator` now owns a single ladder:

```ruby
RETRY_BACKOFF_SEC = [ 5, 10, 60, 300, 900, 3600 ].freeze
```

`retry_delay_sec` indexes it by the retry already charged to the task, so
the steps climb and then hold — the last entry is the ceiling, not a
counter that runs out. The charge comes from `durable_retry_count`, which
reads the highest `retry_count` across that project/slug's recovery
requests, so it survives daemon restarts. `request_retry_delay_sec` reads
the charge off a request's own `recovery` hash when stamping
`next_eligible_at`, and treats a request without one as its first.

A deliberate human retry is no longer held by that pacing:

```ruby
OPERATOR_REQUESTORS = %w[action cli bot web].freeze
```

Those requestors skip the `shared_cooldown` gate, because the ladder
exists to pace Hive's own sweep and gating an operator on it left a task
idle with a person standing over it. Safety checks still apply to them —
those are about worktree state, not pacing.

Consequence for proofs: a test that reparks a failure and then asserts the
marker is still parked must read its window off `RETRY_BACKOFF_SEC` at the
step that retry is actually charged. Measuring against the retired flat
hour now looks for a marker the ladder cleared seconds in — which is how
`daemon_auto_retry_test.rb` turned coverage shard 4/6 red on this branch.

See [[commands/daemon]] and [[testing]].
