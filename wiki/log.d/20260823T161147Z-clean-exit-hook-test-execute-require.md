# Clean-exit hook test requires Hive::Stages::Execute explicitly

`test/unit/stages/base_clean_exit_hook_test.rb` referenced
`Hive::Stages::Execute` when stubbing `recover_committed_residue!`, but only
required `hive/stages/base`. `lib/hive/stages/base.rb` cannot require
`hive/stages/execute` at the top level — `execute.rb` requires
`hive/stages/base`, so the load would be circular — and production reaches the
constant only through `Hive::Stages::Resolver`, which lazily requires
`hive/stages/execute` before any `4-execute` stage runs.

That made the constant available whenever a sibling test file in the same
process had already loaded it, and absent otherwise. Coverage shard 5/6 put the
file in a partition where nothing else loaded Execute, so the test raised
`NameError: uninitialized constant Hive::Stages::Execute` while shards 1-4 and
6 stayed green.

Fixed by requiring `hive/stages/execute` in the test file. No production change:
the resolver's lazy require already guarantees the constant is loaded before
`reconcile_auto_committed_execute_residue` can reach it.
