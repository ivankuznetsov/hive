## 2026-08-15 — ce-doc-review adapter transport coverage

The `CeDocReview` adapter was the largest remaining coverage gap. Its
production `HiveRunner` was only exercised through the artifact-tampering
path, so the whole result-normalization surface ran untested. Tests now cover:

- `HiveRunner#normalize_result` mapping each agent result onto a transport
  status — `:ok` to `ok`, `timed_out` to `timeout`, a limit-shaped
  `error_reason` to `provider_limit` (deriving `retry_at` from
  `Hive::AgentLimit` when the agent reports none), and anything else to
  `retryable_failure`.
- The served-model attestation, which records `model` and `family` on the
  actual route only when the agent reports usage, and stays silent otherwise.
- `HiveRunner#call` rescuing `ArtifactFirewall::Error` as `terminal_failure`
  and `Hive::AgentError` as `retryable_failure` carrying the requested route.
- Adapter-level normalization of `Timeout::Error` and of `SystemCallError`
  and `IOError` as a filesystem failure.
- `default_capability_probe` degrading a raising profile registry to
  `unsupported` instead of propagating.
- `validate_snapshot!` rejecting a plan whose digest drifted after the
  snapshot was taken, before the reviewer is invoked.
- `render_prompt` selecting the adversarial and verification templates by
  request kind, alongside the primary one.
- `validate_output!` treating a missing result as "did not publish" and a
  path outside the disposable directory as an escape.
- `normalize_status` carrying `unsupported` and `terminal_failure` through.
- The disposable-copy mutation guard, which is terminal even when the
  original snapshot is untouched.

`Adapters::Base::Request` also now has coverage for rejecting a malformed
digest or attempt id and a non-positive or non-Integer timeout.

See [[modules/plan_review]] and [[testing]].
