---
date: 2026-08-13
slug: unused-gh-failing-job-facade
pages: [modules/gh]
---

Removed the unused `Hive::Gh.pr_failing_job_logs` wrapper and its direct test.
The babysitter already composes `pr_status_rollup` with
`failing_jobs_with_logs`, whose focused coverage continues to protect job-log
selection, byte budgeting, and tail clipping. Updated [[modules/gh]] to name
the live API.
