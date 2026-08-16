## 2026-08-16 — Make the setup orchestrator test load `babysit.rb` itself

**Problem:** Coverage shard 5/6 errored with
`NameError: undefined method 'prepare_service_takeover!' for class
'#<Class:Hive::Commands::Babysit>'`. `test/unit/commands/setup/orchestrator_test.rb`
required only `hive/commands/babysit/service_installer`, which opens
`Hive::Commands::Babysit` as a bare namespace, so the takeover stub depended on a
co-running shard file loading `babysit.rb`. Shards are a byte-balanced partition,
so growing an unrelated test file reshuffled membership and left the orchestrator
test in a shard with no such co-runner.

**Fix:** Required `hive/commands/babysit` directly in the orchestrator test.
Production was already correct: `Hive::Commands::Setup#install_babysitter` requires
the command inside the phase before calling `prepare_service_takeover!`.

**Verification:** The single test reproduced the `NameError` in isolation before the
change and the full file passes (45 runs, 0 failures) after it.
