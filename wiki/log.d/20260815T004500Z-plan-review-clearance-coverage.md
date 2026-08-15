## 2026-08-15 — Plan review clearance, coverage, and projection branch coverage

Three more plan-review units now have tests behind every branch:

- `Clearance.evaluate` — the gated-finding action wording (approval rather
  than an answer), the `revising` return when a required revision has not
  completed, the `verifying` return once revision is done, and the `blocked`
  return when `CoverageEvaluator` reports missing coverage under `mandatory`.
- `CoverageEvaluator` — a failed disposition verification, which blocks a
  `mandatory` review but only degrades a `standard` one whose core coverage is
  intact; the `InvalidRecord` raise for a malformed coverage entry; and
  `merge` inferring `failed` when the reviewer reports no row at all.
- `Projection` — `empty_summary` rejecting a state or freshness status outside
  the record vocabulary, and `blocker_summary` deriving the blocker owner from
  the review state when no blocker names one.

See [[modules/plan_review]] and [[testing]].

Two further single-branch gaps are closed alongside them:

- `Policy.classifier_version` raising `Hive::ConfigError` on a non-Integer
  `plan_review.classifier_version`.
- `Identity.task_generation` falling back to the slug for a task object that
  exposes neither `id`, `meta_yml_path`, nor `workflow`.
