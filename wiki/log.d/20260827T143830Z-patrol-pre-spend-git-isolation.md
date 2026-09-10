---
date: 2026-08-27
slug: patrol-pre-spend-git-isolation
pages: [modules/agent, modules/agent_git_gate, modules/protected_files, modules/patrol, testing, gaps]
---

Managed Patrol Inbox, Fix, and Review launches now enter a bubblewrap mount
namespace before the provider starts. The namespace begins at a read-only host
root and rebinds only the selected Fix worktree, task-private report/runtime
area, and canonical admitted provider state below HOME. Each child receives
private Git config, refs, objects, and index state at the selected worktree's
normal Git discovery path, without process-wide repository-location `GIT_*`.
The real common/worktree Git metadata, declared Git config locations, and
checked-out submodule pointers remain read-only. Review and Inbox also receive
a read-only code worktree; missing protected paths below writable roots and
provider-state paths outside HOME fail before provider launch.

The Safe Agent Git Gate now prepares and adopts the private metadata, rejects
repository-selected upload-pack hooks and replace-object ancestry, imports the
exact private head without writing `FETCH_HEAD`, re-proves ancestry in the
authoritative repository, and rolls back the exact ref and index when final
verification fails. Real regular, linked-worktree, nested-repository, and
submodule tests deny direct and rename mutations while proving normal private
commits and exact adoption. Missing bubblewrap fails before provider launch,
and cleanup failure retains the private directory without masking the result.
