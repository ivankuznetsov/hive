## 2026-07-18 — Share runtime command error-envelope production

- Migrated approve, findings inspection/toggles, marker clearing, run, workflow
  stage actions, and status/diagnose to `Hive::Schemas::EnvelopeEmitter`.
- Extended the mixin with hooks for composed-command suppression and
  error-specific fields, preserving quiet approve behavior and the final-stage
  field without duplicating the rescue and JSON-write scaffold.
- Kept each published schema, error-kind mapping, exit code, recovery field,
  and single-document stdout guard unchanged. Specialised producers retain
  dedicated emitters when their output destination, schema routing, or wire
  shape differs from the common `ErrorEnvelope` contract.
- Verified the affected command and integration suites together: 221 runs,
  1,027 assertions, zero failures, and zero errors.
