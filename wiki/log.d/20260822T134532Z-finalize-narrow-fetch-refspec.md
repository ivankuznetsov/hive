# Finalize observes the exact remote feature ref

`Stages::Finalize` now determines whether a branch is published by comparing
local `HEAD` with the exact `refs/heads/<branch>` OID returned by
`Hive::Gh.remote_branch_oid`. It no longer depends on `<branch>@{u}`, which Git
cannot resolve when a managed clone's fetch refspec intentionally covers only
the default branch.

This prevents an already-pushed task from cycling forever through
`ERROR reason=unpushed_commits`. A focused integration test narrows the origin
fetch refspec to `main`, proves the upstream expression fails, and verifies
that finalize still completes from the exact remote match. Remote lookup
failures continue to fail closed and flow through the existing push/error path.
