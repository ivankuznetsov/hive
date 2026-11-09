# 2026-11-04 — Accept unquoted `off` for plan_review.adversarial_min_level

- YAML 1.1 parses a bare `off` as boolean `false`, so
  `adversarial_min_level: off` failed validation ("got false") and made the
  whole project config invalid. Config validation now normalizes `false` to
  `"off"`. Found while migrating hivedev to the new review policy.
