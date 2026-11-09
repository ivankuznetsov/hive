## Proposal review contracts hardened

**Action:** Closed the proposal review findings across admission, replay,
lifecycle, context, and publication. Proposal transactions now isolate exact
Git pathspecs and preserve unrelated staging across success and failure;
lifecycle success requires committed-blob proof. Decision callers bind each
considered evaluation ID to its observed result digest, while unrelated evidence
appends remain non-staling. Source admission uses durable aggregate usage and a
bounded hourly actor window, isolates malformed neighbors, terminally
quarantines permanent corruption, and publishes the source index/status schemas.
Replay preserves reserved malformed slots and validates retry lineage.

Automatic context now retains fixed-label numeric evaluation values, distinguishes
no terminal matches from byte-budget exhaustion, and records zero-item truncation
provenance. Evaluator allowlists fail closed through shared configuration/runtime
row validation. Proposal CLI IDs use canonical UUID-v4 grammar, proposal error
kinds are a closed shared vocabulary, and refresh checks compare against the
atomically published managed wiki pair. The attempt value contract advances to
v5 with an explicit runtime-control-plane v2 version-fence migration for the
controller-authored proposal subject binding.

**Verification:** Focused proposal, command, schema, attempt, configuration, and
runtime-control-plane tests, plus RuboCop over the changed Ruby files.
