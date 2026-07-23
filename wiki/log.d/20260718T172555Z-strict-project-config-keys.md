## [2026-07-18T17:25:55Z] config — strict project top-level keys

**Action:** `Hive::Config.load` now validates raw project configuration root
keys before defaults or synthetic values are merged. Supported keys come from
`Config::DEFAULTS`, explicit no-default sections such as `gh`, and exact stage
names from built-in and active project workflow descriptors. Unsupported keys
are aggregated into one deterministic, source-path-bearing `ConfigError`.

A literal top-level `reviewers` key always fails, regardless of its value, with
guidance to move the list under `review.reviewers`. The project allowlist does
not apply to global Hive config. Because the boundary is shared, review runs
stop before reviewer side effects and `hive doctor` exits 78 before running
probes or emitting a successful report.

**Coverage:** Updated [[modules/config]], [[commands/doctor]], and
`docs/workflows.md`. Added focused config/workflow tests plus init, review, and
real doctor subprocess regressions. Did not edit compiled [[log]].
