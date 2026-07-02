# 2026-07-02 — drop the reserved `rate_limited` enum member (arch pass)

Architecture review of the review-error-reason PR (#627): `rate_limited`
was a reserved-but-unemitted member of `Hive::ReviewErrorReason::REASONS`,
justified as "accepted on read" — but nothing anywhere reads REASONS (the
healer keys on the literal `limits_reached`; notification_builders keeps
its own manual-only lists), so the reservation guarded nothing. Removed it:
every REASONS member is now written by exactly one live code path, and the
docstring says to add members only together with the code that emits them.
The wiki ([[stages/review]]) already listed the enum without it.
