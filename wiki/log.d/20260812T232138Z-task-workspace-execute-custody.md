## [2026-08-12T23:21:38Z] fix — preserve attempt activity through agent custody

**Action:** Kept activity receipts within their admitted input generation,
revalidated historical operation receipts against durable attempt lineage,
and moved artifact custody to the exact untrusted provider-call boundary for
execute, publication, review, and managed-worktree agents. Session start now
lands before custody; safe restoration precedes context promotion and terminal
session evidence.

**Why:** A fresh attempt could invalidate itself after admission, strand a
pending approval receipt across retries, and then have legitimate controller
session events restored away as apparent task-journal tampering. The corrected
ordering preserves immutable telemetry without weakening protected-file
checks, and suppresses context/session postwrites when restoration fails.
