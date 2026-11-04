## [2026-11-03T08:54:00Z] Rails task fixtures retry collisions with moved tasks

**Action:** The shared Rails sandbox retains tasks across examples. `create_task!` now
checks a newly created inbox slug against other stages, removes only the new
candidate on collision, and uses its existing bounded retry. This prevents
ambiguous task routes from returning intermittent 404s after earlier tests move
tasks. Helper regressions force inbox and moved-task collisions and verify
unique resolution and preservation of the original folder. See [[testing]].
