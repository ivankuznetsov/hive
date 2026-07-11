## [2026-07-11T08:53:29Z] babysitter — disable interactive gh selectors in dry-run passthrough

**Action:** Set `GH_PROMPT_DISABLED=1` before allowlisted dry-run reads exec the real `gh`, so identifier-less `gh workflow view` and `gh run view` calls fail promptly under a PTY instead of waiting in an interactive selector. Added a PTY-backed regression for both commands.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
