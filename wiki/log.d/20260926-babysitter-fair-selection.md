# 2026-09-26 — Babysitter PR selection round-robins by last attempt

- `ProjectTick#select_prs` sorted candidates by merge-state priority and then
  oldest `updatedAt`, and took `max_concurrent_prs` (default 2). A PR that
  stayed red after every "successful" fix won every tick: on dogfood #1457 was
  worked 13 times and #1461 8 times in six hours, while newer red PRs were
  never selected.
- `fair_order` now sorts by the PR's last fix attempt (`agent-fix`, `rebase`,
  `force-push` in the tail of `babysitter/events.jsonl`) first, with
  never-attempted PRs leading, then by the existing priority and age.
