# Wiki — coalesced backlog-recovery and patrol-finding refresh

Refreshed the managed wiki for queued commits `625431de`, `798998e7`,
`79d37359`, and `c9f31811`. The three overlapping LLM-wiki commits were
inspected as commit snapshots; current [[commands/init]], [[templates]],
[[testing]], and [[gaps]] already describe the final large-backlog recovery,
live drain evidence, and primary-worktree-owned shared runtime, so no duplicate
coverage was added.

Documented the remaining patrol-finding fixes: `hive bench submit` now branches
from the hive-bench remote default and restores the caller checkout;
`hive uninstall` also deregisters Hive web through its service installer;
registered relative and blank `hive_state_path` values normalize before
babysitter status/worktree paths are built; already-green non-behind fork PRs
no-op before the fork label boundary; `base64 >= 0.2` is an explicit PKCE
runtime dependency; and repeat `install.sh` upgrades recognize, temporarily
remove, and failure-restore Hive-managed wrappers. Focused test coverage and
the remaining installed/live-smoke uncertainty are recorded in [[testing]] and
[[gaps]]. Page coverage did not change, so [[index]] was not updated. QMD was
not run because bounded index maintenance is owned by the refresh wrapper.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[commands/uninstall]]
- [[modules/babysitter]]
- [[modules/config]]
- [[dependencies]]
- [[operating]]
- [[testing]]
- [[gaps]]
- [[log]]
