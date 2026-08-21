# Autonomous fix-guardrail bypass and test-password fixtures

**Problem:** `review.fix.guardrail.bypass: true` suppressed only future scans. A
task already paused on `REVIEW_WAITING reason=fix_guardrail` stayed classified
as operator input and still required checkbox edits, so enabling the documented
bypass could not make a hands-off daemon workflow hands-off. The password
scanner also parked the webmail dogfood review on three obvious test values:
`correct` and `system-password`.

**Change:** Existing fix-guardrail pauses now classify as `ready_for_review`
when the explicit project bypass is true, and the resume path accepts the
bypass in place of checkbox approval. Positive match-count validation, guarded
HEAD equality, and clean-worktree validation remain mandatory. The closed
test-fixture password allowlist now includes `correct` and `system-password`
under conventional `test/` and `spec/` paths; production paths and the shared
log/PR-body scanner remain fail-closed.

**Verification:** Focused secret-pattern, fix-guardrail, task-action, and full
review-runner tests cover both exact fixture values and an unchecked persisted
guardrail artifact advancing only under the explicit bypass.

Affected surfaces:

- `lib/hive/secret_patterns.rb`
- `lib/hive/stages/review.rb`
- `lib/hive/task_action.rb`
- `wiki/stages/review.md`
- `wiki/modules/markers.md`
