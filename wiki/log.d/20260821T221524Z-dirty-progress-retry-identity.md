# Productive dirty-worktree retries use commit identity

Pi can deliberately stop after leaving useful changes in its worktree. Hive
captures those changes and records the resulting commit in task-status
evidence before retrying the same execute stage.

Recovery fingerprints now include that controller-observed commit SHA for
`dirty_worktree` failures. A new checkpoint therefore starts a fresh short
retry ladder instead of being charged as another identical failure, while a
repeat at the same revision still accumulates toward deterministic-failure
parking. More generally, any changed typed failure fingerprint starts a fresh
ladder; histories written before fingerprints existed retain their durable
count. Other failure classes keep their existing fingerprint identity.
