# Hosted CI account limits cool down without code-fix attempts

GitHub Actions can create failed checks without starting a runner, leaving no
job log and recording the actual billing or spending-limit cause only in the
check-run annotation. Hive now reads those bounded annotations when job-log
fetching fails. Hosted diagnostics that match the shared provider-limit
classifier return the existing typed `limits_reached` result immediately.

Review therefore writes the normal cooldown-bound `REVIEW_ERROR` and retries
indefinitely through the recovery coordinator after the account changes,
without spending either of the per-cycle code-fix agent attempts on an
infrastructure failure. Ordinary hosted code failures still use the bounded
CI-fix loop, and local test output is never scanned by this hosted-only branch.
