## 2026-08-20 — Patrol Fix owns local fix and validation generations

**Action:** Added the controller-owned `patrol-fix` Inbox, Fix, and Validate
vertical path. Inbox re-investigates current code through a strict semantic
report; Fix creates or recovers one exact local no-fetch worktree generation;
Validate executes only deliberate configured or structured fixer-selected
commands and records bounded redacted evidence even when they fail.

**Authority:** Trusted/YOLO remains a configured execution posture rather than
a containment claim. Agent-written task, receipt, and publication bytes never
authorize a transition. Receipts bind task/evidence generation and exact heads,
one `(task, stage, generation, kind)` terminal tuple is immutable, and receipt
durability precedes a stable slug-locked transition intent. Interrupted moves
reconcile from the intent journal; stage execution and admission-time generation
updates share that lock, both stage parents are synced before acknowledgement,
and generation drift fails closed. Dirty or uncertain owned worktrees are
preserved for recovery. No U3 path authenticates with GitHub, pushes, opens an
issue, or creates a pull request.

Validation marks receipt-level output truncation and retains a result digest
that incorporates omitted redacted bytes.

**Coverage:** Added focused parser, Inbox, Fix, Validate, worktree-receipt,
validation-receipt, receipt-uniqueness, and stage-transition tests; retained the
existing remote draft-PR `AgentWorktree` behavior through a local-custody-only
extraction and characterization test.
