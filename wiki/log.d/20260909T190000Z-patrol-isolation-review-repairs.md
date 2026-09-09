# Repair Patrol isolation startup and controller adoption boundaries

Read-only Inbox and Review now use existing read-only Git metadata, so detached
validation checkouts do not require an adoptable branch or private repository.
Gitlink discovery streams ordinary entries away before its retained-output cap,
allowing large repositories while bounding gitlinks and individual records.
Ordinary Git reads again reject core.worktree; only isolated operations pinning
both Git directory and worktree accept private worktree configuration.

Fix alternates restoration verifies its captured directory identity and writes
through a held Linux directory descriptor, preventing agent-controlled parent
symlinks from redirecting controller writes. Cleanup releases the descriptor and
reports real removal errors. Optional unchanged adoption removes a duplicate
unscoped private-HEAD read. New regressions reproduced all four review defects
before the repairs; targeted kernel/Git/boundary checks pass.
