# Pi zero-exit provider failures recover autonomously

Pi can emit `stopReason: "error"` with a provider diagnostic and still exit
zero. Hive now retains the profile extractor's typed provider error across the
stream and fails the current agent result. Typed quota errors keep
`limits_reached`; other failures become `provider_error` without poisoning the
trusted provider-route health signal.

Execute therefore records a recoverable implementation error instead of
inspecting a partially written worktree as if the agent had succeeded. A
successful execute pass that nevertheless leaves uncommitted agent work also
writes `ERROR reason=dirty_worktree`, allowing the recovery coordinator to
resume the exact owned worktree with its normal cooldown and attempt lineage.

For tasks stranded by the older behavior, the daemon upgrades
`EXECUTE_WAITING reason=dirty_worktree` only when the marker carries a durable
`attempt_id`. Unattributed dirty work remains a human-owned pause.
