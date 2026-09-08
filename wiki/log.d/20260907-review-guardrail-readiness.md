# Review guardrail readiness uses the stage contract

Confirmed that a local TopGreenDeals task remained `needs_input` after removal
of the default lockfile rule even though Review's existing approval reader
returned true. TaskAction had treated every REVIEW_WAITING as a human decision.

Move the pure finding reader to FixGuardrail and share it between status and
execution. Approved or retired-rule-only reports now become runnable; active
unchecked findings and malformed/count-mismatched reports do not. The runner
retains its normal HEAD and clean-worktree checks. Unit tests cover both paths.
