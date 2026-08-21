# Preserve outcome-evidence provider failures

Outcome-evidence inference, producer, and reviewer roles now preserve the
typed failure envelope returned by `Hive::Agent`. Provider credit and quota
walls publish the shared `limits_reached` marker with provider and cooldown
metadata, allowing daemon-owned recovery to wait instead of hot-looping the
same large prompt. Non-limit typed provider failures retain their provider,
status code, and bounded diagnostic. Contract, custody, and malformed-output
failures continue to use `outcome_evidence_invalid`.
