---
timestamp: 2026-06-30T08:50:12Z
slug: review-fix-stop-hook-recovery
---

**Action:** Added operator recovery guidance for tmux review-fix Stop-hook timeouts, including the constrained `hive markers clear FOLDER --name REVIEW_ERROR --match-attr phase=fix,reason=fix_failed` command and the evidence checklist for tasks 58 / PR #622, 287 / PR #623, and 288 / PR #624.

**Why:** Clearing a terminal review marker without artifacts plus commit/no-change proof can mask a real fix failure. `claude.mode: headless` remains the recommended workaround for affected versions and service hosts.

**References:** [[stages/review]]
