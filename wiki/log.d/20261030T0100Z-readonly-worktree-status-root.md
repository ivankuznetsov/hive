# 2026-10-30 — Read-only `hive worktree status` and `runtime projects` worktree roots

- Consumer: hivedev's read-only workspace audit, which mounts a Hive state root
  read-only in a container. Two gaps remained after the read-only
  `runtime projects`/`runtime payloads` listings.
- `hive worktree status TARGET [--project P] [--stage S] [--json]` is now
  eligible for the one-shot operational-inspection fallback
  (`OperationalInspection.eligible_route?`), so on a procfs-confirmed
  read-only state root it reports instead of exiting 69 with
  `state_storage_read_only`. The matcher fails closed on any other switch;
  `commit-residue`, `discard-residue`, and `repair` stay ineligible.
- Write audit of the status path: no lock, marker, runtime transaction, or
  `git worktree prune`; the one write found was plain `git status`
  refreshing the worktree index stat cache. The porcelain read now passes
  `--no-optional-locks`.
- `hive runtime projects` reports each project's effective `worktree_root`
  via a raw project config read and `Hive::Worktree.canonical_root`. A
  missing, unreadable, or invalid config, a non-string value, or an
  unexpandable value gives `worktree_root: null` plus `worktree_root_error`
  for that project only. `hive-runtime-maintenance.v1` gains the optional
  pair (additive, still v1).
- Updated [[commands/runtime]], [[commands/status]], [[modules/worktree]], and
  [[gaps]].
