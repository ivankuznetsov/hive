# 2026-08-30 — Keep derived checkpoints out of reviewer custody

Plan reviewers no longer fail with a false protected-artifact violation when
Hive refreshes `task-projection.checkpoint.json` during the reviewer session.
The derived checkpoint now follows the existing exact-window exclusion for the
task journal and projection; canonical plan, metadata, and plan-review authority
records remain protected and restorable.

The owning adapter test now pins all three Hive-written bookkeeping files so a
future projection artifact cannot silently reintroduce the same live-review
failure.

Existing blocked records automatically retry each exact runner-authored false
positive once for the primary and adversarial roles. A versioned recovery reset
prevents persistent or reviewer-authored custody failures from creating a loop.
