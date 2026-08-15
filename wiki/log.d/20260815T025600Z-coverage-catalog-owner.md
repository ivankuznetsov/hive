# Restore one exact coverage catalog owner

The six coverage collectors now assign full `lib/` source-catalog preload to
shard zero only. The remaining five collectors stay lazy, preserving the
bounded subprocess behavior introduced after redundant preloads caused
coverage-aware `exit!` flushes to exceed test deadlines.

This restores the exact gate's ability to report files that no test requires:
hosted run `31840261225` exposed five such files after every shard was made
lazy. The shard-preparation contract now proves one catalog owner and lazy
non-owner shards. Historical exact-head run `31824441577` already passed all
23 gates with this ownership split; the rebased head still requires fresh
hosted validation.

The rebased local checkpoint passed the focused coverage contracts (26 runs,
240 assertions), the standalone runtime component (48 runs, 448 assertions),
and the broad root suite (13,463 runs, 191,648 assertions) with no failures or
errors.
