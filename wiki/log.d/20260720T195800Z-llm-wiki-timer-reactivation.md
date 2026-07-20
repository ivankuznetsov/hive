# 2026-07-20: Make llm-wiki timers reactivation-safe

**Action:** Changed generated Linux llm-wiki timers from boot-relative
`OnBootSec=10min` to activation-relative `OnActiveSec=10min`, while retaining
`OnUnitActiveSec=1d` for the daily cadence. Removed the ineffective
`Persistent=true` setting for the monotonic timer. A timer installed or
re-enabled more than ten minutes after boot now gets a concrete first trigger
instead of remaining `active (elapsed)` indefinitely.

**Tests:** Extended the init scheduler contract to require the activation delay
and daily cadence and to reject the stale boot-relative/persistent directives.
