# 2026-09-25 — Durable attempt interruption

- Durable attempts now represent a quiescence stop as terminal
  `interrupted`, with the pause generation, final checkpoint, outputs, and log
  retained in the strict receipt.
- The attempt supervisor distinguishes a quiesce signal from ordinary
  cancellation, preserves genuine natural completion, clamps termination to
  the persisted quiescence grace/deadline, and uses the admitted worker's one
  cleanup-write window after admission closes.
- Restart reconciliation publishes interruption only after identity-based
  wrapper and worker-group absence proof. Terminal compare-and-swap races keep
  an independently committed success authoritative.
- Attempt condition, execute-repair, recovery-marker, daemon replay, and retry
  pacing consumers treat interruption as non-success without manufacturing a
  completion marker.
