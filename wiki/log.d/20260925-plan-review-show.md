# 2026-09-25 — `hive plan-review TARGET show`

- Added the read-only, lock-free `hive plan-review TARGET show [--json]`
  (`hive-plan-review-show.v1`). It returns the live review id, task generation,
  policy fingerprint, observation digest, state, required action, the same
  freshness verdict decisions are checked against (so a review of an older plan
  is reported before a decision is attempted), and open findings ordered for
  display. Decisions previously had to copy identities from
  `hive status`, whose operational view can be a daemon-cached snapshot about a
  minute old, so chained decisions failed with `stale_decision`.
