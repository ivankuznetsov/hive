## [2026-11-01T23:16:02Z] review — preserve withholding and exact-head proof

**Action:** Kept incomplete-fix publication withheld through entry CI until a
fix receipt exists. Missing local proof after hosted CI repairs reruns against
the repaired HEAD without repair. Approval invalidates a withheld publication
attempt at the same HEAD; a publisher attempting a different HEAD starts fresh
evidence.

**Context:** Four review findings exposed stale publication and combined-CI
proof during recovery. Focused unit and integration regressions cover these
boundaries; live hosted PR behavior remains a documented validation gap.

**References:** [[stages/review]], [[publication-recovery]], [[gaps]].
