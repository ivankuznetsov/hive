## [2026-06-27T05:43:37Z] tui/status — keep archive scans off the 1 Hz TUI poll path

**Action:** Reworked `Hive::Tui::StateSource` so the steady-state poll parses
active stages only and merges those rows with a frozen archived-row cache.
Archived `9-done` task files are excluded from the active mtime fingerprint;
the poller watches only active row state files/locks plus active stage dirs,
and tracks each project's `9-done` directory mtime as a cheap archive-set dirty
signal. Archive cache rebuilds run on a short-lived background refresher and
are also requested when the archive pane opens.

**Status seam:** Added default-preserving `Status#json_payload(stages:,
extra_dependency_tasks:)` plumbing so the TUI can reuse the existing row builder
for active-only parses while keeping dependency resolution correct for active
tasks that depend on archived prerequisites. No-kwargs status output remains the
full snapshot for CLI/daemon/web/bot consumers.

**Coverage:** Added a parseable TUI scale fixture, an opt-in diagnostic profile,
and a default perf gate asserting idle ticks and active reparses do not grow with
archive size. Expanded StateSource tests for archive fingerprint exclusion,
archive refresh/dedup, liveness fallback, archived dependency identities,
registry project-set changes, and refresher teardown.
