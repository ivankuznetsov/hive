---
date: 2026-06-18
slug: task-dependencies-review-03
pages: [modules/daemon]
---

Review pass 03 hardening for same-project task dependencies.

Behavior-observable change: the daemon's once-per-tick status advisory is now
logged under the neutral event `:status_warning` (renamed from
`:status_schema_skew`). That channel carries both a tolerated forward
schema-version skew AND status-command stderr breadcrumbs (fail-open
dependency gate, dropped `depends_on`), so the schema-specific name was
misleading — an operator grepping daemon.log for dependency-gate degradation
never found it. Renamed in `Hive::Daemon::Logger::EVENTS` and refreshed
[[modules/daemon]].

Correctness/observability fixes: `Worktree.fetch_origin_branch` now writes the
`refs/remotes/origin/<branch>` tracking ref via an explicit colon-refspec so
dependency stacking no longer collapses onto the default base on
single-branch/narrow-refspec clones; `Commands::Status#dependency_gate_stage_for`
warns the gate-loosen direction on a config-load failure; the
`Dependencies.task_id` breadcrumb comment was corrected (corrupt id fails to
resolve, not mis-resolves).

Added regression coverage: real-git `origin_branch_exists?` (incl. narrow
refspec), the `TaskMeta.read` two-arm rescue (warn vs silent), the per-row
dependency fail-open, the blocked single-source-of-truth invariant, and
absence checks that an unblocked dependent omits the held indicator.
