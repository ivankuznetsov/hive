# Sync the canonical single-project bench runtime

**Date:** 2026-08-11

**Action:** Refreshed Hive's built-in `bench` runtime from the consolidated
`hive-bench` source. Candidate model and effort declarations now flow through
Hive's provider-neutral `models:` routes and the shared Agent CLI Runtime;
benchmark-owned Codex and Grok model wrappers were removed. Added the Opus 5
and Fable 5 planner variants with Sol-high execution and the Sol/Opus review
panel.

**Architecture:** Maintained campaigns are tasks in one registered
`hive-bench` project. The copied `.hive-state/bench-runtime` is workflow data,
not another Hive installation or scheduler. Cell-local Hive processes remain
isolated because they are the system under measurement.

**Validation:** The source runtime and installed project snapshot matched for
all six changed files; the source benchmark suite passed 315 runs and 1,117
assertions. Hive's focused built-in workflow tests cover packaged routing and
candidate presence.
