# Multiple task dependencies

**Action:** Extended task dependency declarations from one scalar reference to
a shape-preserved scalar or nonempty flat list. Repeated
`hive new --depends-on` flags construct the list; a singleton array remains
list policy.

**Behavior:** Scalars retain the depending project's configured gate and
eligible same-project Git stacking. Lists are scheduling-only, branch from the
project default, and require every prerequisite to reach `9-done`. Adding a
second CLI flag changes the first edge to list policy and emits a stderr notice.
Creation rejects resolvable cycles, while shared admission revalidates current
cycles and unreachable workflow gates. Forward `--force` cannot bypass a wait.

**Projection:** `hive-status.v9` and `hive-operational-status.v5` publish
scalar-or-array `depends_on`, ordered `unmet_dependencies` entries with
`required_gate`, and `dependency_base_mode`. List rows keep the legacy singular
`blocked_by` and `dependency_stage` fields null. Daemon coherent snapshots and
status caches use v2 for the same shape.

**Operations:** Upgrade every CLI, daemon, Web reader, validator, and operating
skill, restart long-lived processes, and only then create list metadata. Array
metadata is a no-downgrade boundary; preserve every edge during remediation.

**Coverage:** Added an integration scenario with nine prerequisites proving the
configured scalar gate, fixed list `9-done`, exact remaining blockers, force
non-bypass, and release after every prerequisite completes. Updated
[[modules/task_dependencies]], [[commands/new]], [[commands/status]],
[[stages/plan]], [[modules/task_workspace]], [[modules/plan_review]],
[[modules/daemon]], [[modules/config]], and [[decisions]].
