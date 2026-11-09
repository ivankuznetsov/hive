# 2026-11-03 — Review and plan-review convergence defaults

An audit of eleven hivedev tasks (275 code-review findings) found passes 1–2
catching nearly all real defects, triage accepting 100% of findings, ~15% of
findings being release-evidence gates every fix commit re-triggered, and
adversarial plan review growing plans 25–170% without improving code-review
outcomes. Defaults now converge:

- `review.max_passes` 3 → 2 (two fix passes, then one verify-only pass).
- New `review.severity_gate_from_pass` (default 2): later passes fix only
  evidenced High findings; Medium/Low/Nit become `DEFERRED`, which does not
  start a fix pass or block completion and is summarized in
  `reviews/deferred-findings.md` for at most one follow-up.
- Reviewer and triage prompts ban release-evidence findings, triage rejects
  out-of-scope / implausible / negligible findings with a reason, and
  verify-only passes report only unresolved or regressed findings
  (`Hive::Stages::Review::Convergence`).
- Plan review: adversarial lens only at `plan_review.adversarial_min_level`
  (default `mandatory`); `plan_review.max_revision_rounds` defaults to
  `standard: 1`, `mandatory: 3`; the planner keeps evidence gates in the
  Definition of Done.
