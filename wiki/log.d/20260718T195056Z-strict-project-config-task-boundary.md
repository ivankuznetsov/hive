## [2026-07-18T19:50:56Z] fix — preserve strict config failures at task boundaries

**Action:** Classified unsupported project root keys as
`UnsupportedProjectConfigError`, preserving the `ConfigError`/exit-78 contract
while preventing workflow-directory and task default-workflow fallback paths
from converting the shared validation failure into the built-in `coding`
workflow. Recoverable malformed or unreadable config fallback behavior remains
unchanged.

**Coverage:** Added focused workflow-loader and task regressions plus a real
`approve` mutation-boundary check that leaves the task in its original stage.
Updated [[modules/config]] and [[modules/task]].
