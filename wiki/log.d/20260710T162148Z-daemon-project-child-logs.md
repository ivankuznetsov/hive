# Keep daemon child logs out of shared tmp and project Git state

Daemon dispatches now pass Hive's XDG state home to `ChildSupervisor`. Combined
child output lands under `logs/daemon-children/<project>/<slug>/` instead of the
machine-wide tmpdir, preventing an unrelated `/tmp` quota exhaustion from
crashing the dispatcher before `Process.spawn`.

The capture directory is also outside each project's tracked `.hive-state`
worktree, so a child cannot dirty workflow Git state by emitting its final JSON
envelope after the stage commit. The tmpdir layout remains only for standalone
supervisor callers without a supplied state home. Dispatcher tests pin normal
row and request-queue routing; an integration test verifies the resulting log
location.
