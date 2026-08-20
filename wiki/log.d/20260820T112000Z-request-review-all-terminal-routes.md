## [2026-08-20T11:20:00Z] plan review - recover every current terminal route

**Action:** Make `request-review` append a recovery reset for every reviewer
role whose current effective route is `unsupported` or `terminal_failure`.

**Why:** A Webmail review had terminal failures for both required primary and
optional adversarial routes. The action searched raw history backward, reset
only the later adversarial row, and every replay selected that same historical
row again. The required primary failure could never be reached, so the
documented recovery lever could not recover the review.

**Contract:** Route selection now examines the latest effective row separately
for primary, adversarial, and verification. Successful and transient rows are
left alone; all current recoverable terminal rows reset together under the one
freshness-bound operator decision. Verification findings still require a new
linked plan and remain ineligible for this action.

**Verification:** The decision-service regression pins mixed primary
`terminal_failure` plus adversarial `unsupported`, asserting two ordered reset
rows with no forged attempt IDs. The focused file passes with 14 runs and 60
assertions; focused RuboCop is green.
