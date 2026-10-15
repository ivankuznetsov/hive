## 2026-08-10 — Add explainable provider circuits and audited controls

**Action:** Added `hive circuits` as the direct, approval-requiring operator
surface for explicit provider routing. Its human and `hive-circuits.v1` JSON
views join bounded durable route decisions, attempt-derived provider-account
capacity, and provider-account/exact-model journals without rerunning route
selection. Current decision cells now retain project identity and the optional
admitted attempt ID, so both selected and first no-route/capacity observations
remain explainable after restart.

`block`, `unblock`, and `reset` require `--yes`, a validated single-line reason,
trusted local actor identity, and fresh generation CAS. Corrupt reset instead
requires the complete inspection token, quarantines exact bytes into a new
epoch, preserves the last verified manual block, and fences token reuse.
Provider administration remains absent from `hive act` and cannot touch task
markers, recovery receipts, charges, deadlines, successors, or dispatch.

Operational status advanced to `hive-operational-status.v4` with a required
nullable exact routing decision. The daemon records the decision at admission
and carries it through its coherent snapshot; status never recomputes it, and
legacy rows retain their prior text. Component boundaries now distinguish the
pure routing policy from the read-only routing-operations projection.
