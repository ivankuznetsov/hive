# A loss that never started refunds its daily slot

The daily admission cap counts acceptances, and `refund_tempfail` was the
only way to give one back — fired solely when a receipt carried
`Hive::ExitCodes::TEMPFAIL`. Every other outcome kept its charge, so a
launch that never spawned an agent cost exactly as much budget as a full
run, and a night of failed handoffs could exhaust the day and lock out the
runs that would have succeeded. That is the opposite of what a spend bound
is for.

`Hive::Attempts::Store#first_heartbeat` stamps `started_at` at the
launching → running transition, so a lost attempt without one provably
never spawned an agent and spent no tokens. Those now refund through a
second, narrower door:

```ruby
def refund_unstarted(record)   # Hive::Attempts::DecisionIndex
```

It rejects anything that is not `lost`, and anything that already has a
`started_at`. `FinalizationMaintenance#publish_indexes` calls it on the
loss branch when `record["started_at"].nil?`. Losses *after* starting keep
their charge — the agent ran, the tokens are gone, and the cap bounds
spend rather than counting successes — so this deliberately does not
refund crashes, provider errors, or any other failure that burned real
work.

The v4 migration invariant had to change with it. `durable_daily_counts`
re-derived the refund flag and demanded an exact match, which would have
declared pre-existing history corrupt: unstarted losses recorded before
this change are legitimately still charged. It now checks that every
refund is *justified* (a TEMPFAIL receipt, or a loss that never reached
`running`) rather than predicting which refunds exist. An unrefunded
TEMPFAIL remains an error, since that refund has always been mandatory.

Because the invariant is one-directional now, its two rejection paths need
separate proofs — a single "flag disagrees" case no longer reaches both.

See [[modules/attempts]] and [[testing]].
