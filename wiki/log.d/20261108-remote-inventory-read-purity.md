# Remote acceptance inventory read purity

The remote acceptance checkout inventory hashed `.git/index` before invoking
`git status`, which could refresh the index's stat cache and make the next
inventory report a false remote-isolation failure. Disable optional Git writes
in the inventory's Git helper. The creation/approval acceptance test now forces
stale tracked-file timestamps and requires consecutive inventories to match
before any remote commands run. Updated [[testing]] and retained the pending
coverage-shard rerun evidence in [[gaps]].

Validation: the strengthened test failed before the fix on its consecutive
inventory assertion. After the fix, the remote acceptance and operations
suites passed together (7 tests, 475 assertions), and the acceptance file
passed RuboCop. Full coverage remains the CI runner's next checkpoint.
