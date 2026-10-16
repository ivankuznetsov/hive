# 2026-10-16 — Foreign task ids park as operator repairs; status points at waiting work

- Recovery for topgreendeals.co.uk `preview-only-prepare-the-top-260901-b765`
  failed on every daemon tick with `recovery_unavailable` /
  `IdentityError: task 1 belongs to a different registered subject`. The task
  was created on 2026-09-01 by an OpenClaw agent that ran `hv new` with a
  throwaway `HIVE_HOME`, whose fresh runtime database allocated id 1. The live
  installation had bound id 1 to a hive-project task at the SQLite cutover.
- `TaskLeaseRepository#identity_conflict` adds a read-only probe that names the
  owning subject. The `task_identity_conflict` error now includes that owner
  plus a repair `action` and `details`.
- `Daemon::AutoRetrySafety` runs the probe first, so automatic recovery returns
  `safety_blocked` with owner `operator` before it tries the lease. Operational
  status shows the task as `needs_repair` instead of an eligible retry.
- Human `hive status` now prints
  `Waiting, blocked, and queued work: hive status --operational` after its
  running-task block. The JSON contract is unchanged.
- See [[state-model]], [[commands/daemon]], [[commands/status]], and [[gaps]].
