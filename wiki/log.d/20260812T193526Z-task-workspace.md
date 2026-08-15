## [2026-08-12T19:35:26Z] feature — add the bounded task-detail workspace

**Action:** Added forward repository/wiki/context receipts, exact attempt and
child-session observations, attributed usage and typed resources, an
append-only activity timeline, a bounded connected dependency projection, and
an isolated cached publication preview. The existing task page and
authenticated JSON now share `hive-task-workspace` v1 while preserving native
questions, actions, artifacts, media, diff, log, archive, and live-update
ownership.

**Why:** Operators previously had to correlate durable task state, attempt
records, resource evidence, dependencies, Git state, and GitHub observations
across tools. The shared projection makes their authority, freshness,
conflicts, truncation, and legacy gaps explicit without changing
`hive-status` v7, adding lifecycle mutations, or putting network work in status
broadcasts.
