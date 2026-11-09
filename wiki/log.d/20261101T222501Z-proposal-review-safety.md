## Proposal persistence and refresh ordering hardened

**Action:** Secret-shaped evaluation metric names are redacted before immutable
persistence, and redaction collisions fail closed. Producer admission,
lifecycle mutation, and reconciliation now share committed proposal-state
restoration under the Git commit lock. Malformed source-quarantine reason
objects remain isolated diagnostics, while decision projection quarantines
considered-evaluation snapshots that contradict their referenced evaluation.

Bounded wiki refreshes retain a previously compiled descendant proposal source
when a later SHA-ordered batch contains its ancestor. A proposal-only first
batch can still skip provider serialization, but any later ordinary batch must
acquire the machine-wide provider lock before launching an agent.

**Verification:** Complete proposal unit and integration coverage plus focused
managed wiki refresh regressions for cross-batch ancestry and lazy provider-lock
acquisition.
