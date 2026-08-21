# Retry incomplete plan-verification receipts

Plan-review disposition verification now distinguishes an incomplete success
receipt from a contrary verdict. When a verifier returns `success`, emits no new
finding, but omits one or more required fingerprint-bound `residual_evidence`
rows, Hive preserves every verified disposition and automatically retries only
the missing targets.

The retry uses a verification-route recovery reset and shares the configured
`plan_review.attempts.max_transient` bound. Repeated omissions block after that
bound, while any real verification finding continues to block immediately.
This prevents one accidentally omitted receipt from parking an otherwise
verified candidate until an operator manually starts another review.
