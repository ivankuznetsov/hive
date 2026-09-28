# 2026-09-28 — Post-rework evidence strictness applies only to malformed packages

- The 2026-09-27 rule disabled best-effort evidence for every failure once a
  reviewer rework was on record. That also caught infrastructure limits: a task
  whose evidence tooling could not keep terminal fixtures between commands or
  show browser projects (`outcome_evidence_capability_blocked`) could never
  complete, even though those limits are what best effort exists for.
- The rule now holds back only `outcome_evidence_invalid` (a malformed package)
  after a rework. Quota, blocked capture capability and exhausted recaptures
  still fall back to best effort.
