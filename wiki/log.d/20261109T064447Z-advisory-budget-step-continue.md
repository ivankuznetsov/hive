## 2026-11-09 — incident duration budget stays green when only advisory

`incident duration budget (advisory)` moved `continue-on-error` from job level
to the budget step and reports the outcome in the step summary plus a warning
annotation. A job-level `continue-on-error` keeps the workflow green but still
publishes a failed check run, and Hive's 6-review remote CI gate treats any
failed check as red CI, so tasks hit `REVIEW_CI_STALE` on an advisory signal.
