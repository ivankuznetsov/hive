## 2026-11-08 — Preserve manual retry outcomes and bounded observations

- Keyed manual stage failures retain the evaluated action payload while storing
  a failed command receipt with the stage error exit status. Authoritative
  result recovery also preserves failure rather than converting it to success.
  Rejected action replay retains typed errors and their command extras.
- Remote dispatcher refusal keeps its code and status on replay; the CLI
  reconstructs exact local retry guidance from validated caller inputs and
  matching canonical slug evidence when the caller used a numeric task ID.
- Live manual attempts suppress routine recommendations in the shared action
  descriptor. Evidence read failures, disappearing requests, and failed
  best-effort dispatch deferral return typed unavailable evidence.
- Controller workflows retain their own receipt-based status and do not join
  manual marker recovery evidence.
- Status reads bounded requests once per project and reuses evidence across
  full/lean projections; healthy tasks skip extra marker reads. Action guards
  reuse configuration/coordinator handles and refresh task/request observations.
- Added regression coverage for pre-admission races in both winner orders,
  mixed ownership, not-yet-due cleared requests, noninteractive backoff and
  failure ceilings, and focused ManualRetry/API rejection and orchestration.
- Task-inspection remediation uses `Shellwords.join` in both operational
  status and the daemon's admission-failure logger.
- Validation: 438 focused tests and 2,501 assertions pass. The broad local
  checkpoint remains limited by the existing process-custody/registry failures
  recorded in [[gaps]]; controller status regressions it exposed were fixed
  and included in the final focused run.
