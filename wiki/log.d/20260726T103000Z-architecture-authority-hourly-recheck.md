## [2026-07-26T10:30:00Z] daemon — pace revoked architecture actions hourly

**Action:** Kept revoked architecture-patrol actions nonterminal and resumable,
but changed their policy recheck from the ordinary 60-second transient backoff
to a one-hour cadence. This prevents a permanently changed validation command
or disabled action gate from spawning the same no-op action child every daemon
minute. Restoring compatible authority still makes the action eligible at the
next hourly probe; unrelated transient action failures remain on their existing
one-minute retry.

**Tests:** Extended the action-runner revocation regression to assert the exact
one-hour durable `next_eligible_at` while retaining the no-second-run proof.
