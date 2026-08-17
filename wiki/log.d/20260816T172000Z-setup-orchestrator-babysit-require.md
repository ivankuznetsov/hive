## 2026-08-16 — Make the setup orchestrator test load `babysit.rb` itself

**Problem:** Coverage shard 5/6 errored with
`NameError: undefined method 'prepare_service_takeover!' for class
'#<Class:Hive::Commands::Babysit>'`. `test/unit/commands/setup/orchestrator_test.rb`
required only `hive/commands/babysit/service_installer`, which opens
`Hive::Commands::Babysit` as a bare namespace, so the takeover stub depended on a
co-running shard file loading `babysit.rb`. Shards are a byte-balanced partition,
so growing an unrelated test file reshuffled membership and left the orchestrator
test in a shard with no such co-runner.

The same reshuffle broke `test/unit/commands/uninstall_test.rb` in shard 4/6 with
`uninitialized constant Hive::Commands::Babysit`, because `Uninstall` also requires
the command lazily inside `stop_foreground_babysitter`.

**Fix:** Required `hive/commands/babysit` directly in both tests. Production was
already correct: `Setup#install_babysitter` and `Uninstall#stop_foreground_babysitter`
each require the command before using it.

**Verification:** Both tests reproduced their `NameError` in isolation before the
change; afterwards the orchestrator file passes 45 runs and the uninstall file 46
runs, with no failures. Isolation runs over the 56 test files whose constant
references are not statically reachable from their own requires found one more
latent case — `workflow_package/transaction_test.rb` never loaded
`hive/workflow_package/mutation_lock` — which got the same one-line require. Every
other flagged file already loads its constants transitively and passes standalone.
