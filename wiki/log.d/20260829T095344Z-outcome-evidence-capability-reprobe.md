## 2026-08-29 — Outcome-evidence capabilities recover without stale replay

**Action:** Fixed visual evidence capture for ordinary project applications.
Hive now verifies a non-Hive managed browser session on `about:blank`, lets the
producer start the changed app on the issued loopback port, and only then opens
the private capture origin. Controller-managed Hive Web capture still opens its
already-running runtime during preflight.

Existing `capability_blocked` pointers are now re-probed on a paced retry rather
than replayed forever. Browser startup has a 30-second deadline distinct from
the 10-second teardown bound, so a cold managed Chrome launch is not mistaken
for a missing capability. Reviewer blocks and exhausted recapture decisions
remain operator-owned.

**Verification:** Capture-toolkit tests distinguish ordinary-project blank-page
bootstrap from Hive Web navigation and startup from close deadlines. Artifacts
stage tests prove an existing capability pointer invokes a fresh preflight, and
the pinned managed browser completes that preflight against the Screenote
worktree without modifying it.
