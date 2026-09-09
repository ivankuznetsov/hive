## [2026-08-26T01:45:00Z] Keep incident timing advisory bounded on hosted runners

**Why:** The provider-limit incident passed its semantic assertions but took
10.119 seconds in two hosted CI attempts, narrowly exceeding the ten-second
per-scenario advisory cap. The aggregate remained 21.442 seconds under its
thirty-second budget.

**Change:** Raised only the per-scenario cap to twelve seconds. The aggregate
limit and the strict less-than boundary remain unchanged, preserving a bounded
signal for material regressions while avoiding normal subprocess-runner noise.

**Verification:** The incident-budget unit boundary now proves twelve seconds
fails; hosted CI is rerun on the amended PR head.
