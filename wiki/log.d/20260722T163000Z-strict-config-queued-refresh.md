## [2026-07-22T16:30:00Z] wiki — refresh queued strict-config propagation coverage

**Action:** Inspected queued commits `1d8c4637`, `97259f74`, `a4df6cd8`,
`ae908e77`, `c4068bf5`, and `e219f115` as immutable source blobs. Refreshed the
strict project-config contract across [[modules/config]], [[modules/task]],
[[commands/doctor]], and [[testing]]: exact descriptor stage names are the
dynamic root-key extension point; unsupported keys retain the shared exit-78
path through Doctor, review, ordinary tasks, and managed workflow resolution;
Doctor fails before probes; generated config and nested reviewers remain valid;
and hostile key rendering cannot mask the configuration error.

**Uncertainty:** None of the supplied SHAs is an ancestor of the refresh
branch. Current default-branch source still lacks the strict root-key validator
and typed unsupported-key exception, so [[gaps]] records the queued contract as
branch-dependent rather than confirmed integrated behavior. The two
compiled-log-only commits required no page contract change, and compiled
[[log]] was not edited. Page coverage stayed at 94, so [[index]] did not change.

**Refreshed pages:**

- [[commands/doctor]]
- [[gaps]]
- [[modules/config]]
- [[modules/task]]
- [[testing]]
