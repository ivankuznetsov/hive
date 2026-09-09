# Deterministic recovery parks now expire with their Hive runtime

**Problem:** A Pi artifact attempt dirtied its frozen implementation worktree,
then repeated the same `outcome_evidence_invalid` diagnostic enough times to
reach deterministic-failure parking. The file was removed and a repaired Hive
artifact runtime was deployed, but the coordinator counted the old runtime's
failures and parked the repaired runtime before it received one attempt. The
documented remediation said to change the implementation, while the only
implemented release path was a manual `workflow.retry` action.

**Change:** Recovery failure fingerprints now include a digest of the active
Hive Ruby source and launcher. A deterministic park remains inert for the exact
same runtime, but a restarted daemon with changed implementation bytes
atomically releases the existing guarded request, resets its short retry
ladder, and dispatches normally. The request identity and audit history remain;
no marker is cleared before the ordinary recovery transition revalidates task,
generation, worktree safety, and provider health.

This lets a harness repair heal its own parked dogfood task without weakening
the protection against a genuinely unchanged retry storm or requiring an
operator to babysit the workflow.

See [[daemon]].
