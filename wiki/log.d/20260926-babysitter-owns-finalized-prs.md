# 2026-09-26 — The babysitter owns PRs whose finalize already completed

- `ProjectTick#pipeline_owned_branches` protected every non-terminal task's
  branch, including `8-finalize` tasks whose finalize had completed. Those tasks
  only wait for their PR to merge (the daemon logs `ready_to_archive` /
  `pull_request_merge_pending`), so when `main` moved and the PR's CI went red,
  the pipeline did not act and the babysitter skipped it as `pipeline_owned`.
  Two finalized task PRs sat with red coverage checks and no owner.
- A coding `8-finalize` task whose `pr.md` marker is COMPLETE no longer owns its
  branch. A finalize still in progress, or an unreadable marker, keeps the
  protection.
