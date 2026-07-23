## [2026-07-23T08:36:08Z] testing — move expensive outer proofs to CI merge gates

**Action:** Removed `WebPackagedBootstrapTest` and `TuiReactivityPerfTest`
from the default local `rake test` / `rake coverage` file set and exposed each
through an explicit Rake task. CI runs those tasks as the separately named
`packaged Hive web bootstrap` and `TUI reactivity performance` checks so branch
protection can require them without charging every agent checkpoint for real
gem/web bootstrap or the 8-by-200 TUI scale fixture.

**Agent workflow:** Added repository guidance to run focused test files while
implementing, use the broad default suite once at an appropriate checkpoint,
and leave exhaustive coverage plus packaging/performance proofs to CI unless
diagnosing a corresponding CI failure. The packaged-web task remains
commit-bound because it reproduces the release archive from `HEAD:web`.

**Gate activation:** Do not rely on the split until both new check names have
run successfully on the pull request and `main` branch protection requires
them. Re-query branch protection after the update; the workflow definition
alone does not make a check merge-blocking.

**Measured follow-up:** After removing the two original hotspots, a diagnostic
verbose default-suite profile took 561.565 seconds. It ended with one failure
and one error, so its timings are inventory evidence rather than a green gate.
The next clear candidates for future CI partitioning or focused internal
optimization were multi-agent setup convergence, the babysitter subprocess
security matrix, TUI attachment smoke, setup-orchestrator failure integration,
and brainstorm/tmux integration.
