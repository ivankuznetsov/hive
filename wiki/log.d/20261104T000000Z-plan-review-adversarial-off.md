# 2026-11-04 — plan_review.adversarial_min_level accepts "off"

- `plan_review.adversarial_min_level` now accepts `off`, which disables the
  adversarial plan-review leg at every level. Projects whose plans are always
  classified mandatory (e.g. auth/concurrency-heavy repositories) previously
  could not opt out of the adversarial lens, even though the default policy
  (PR #1597) makes it optional.
