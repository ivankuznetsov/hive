# 2026-09-27 — Evidence best effort is disabled after a reviewer rework

- `Stages::Artifacts.run!` turned any non-integrity evidence failure into
  `COMPLETE reason=evidence_best_effort evidence_status=unavailable`. After the
  evidence reviewer had sent a task back for implementation rework, the next
  round's producer attached the wrong proof kind to one claim
  ("requires document proof, not terminal"). The package was invalid, best
  effort applied, and the task went to finalize with no evidence of the
  reworked behavior at all.
- When a reviewer rework receipt is on record, evidence failures now keep
  their retryable `ERROR` instead of falling through to best effort.
