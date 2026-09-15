# Invalid cancellation receipts remain dependency blockers

Dependency admission now uses the closure reader for terminal prerequisites even when closure.json is absent, so quarantined invalid receipts remain visible. Invalid receipt errors enter the existing dependency validation result instead of treating cancellation as ordinary delivery. Admission does not quarantine or rewrite evidence.

The regression covers a cancelled task with a preserved dirty worktree, corruption of its receipt, and continued blocking through full and active admission after quarantine. Tasks without closure evidence retain ordinary stage-based dependency behavior.
