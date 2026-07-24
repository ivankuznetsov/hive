## [2026-07-23T12:57:17Z] testing — isolate setup and babysitter outer proofs

**Action:** Added `SetupAgentsIntegrationTest` to the canonical file-level
CI-gate map and split the one large babysitter command-classification matrix
into its own filtered gate. The normal local `rake test` and exhaustive coverage
file set exclude the setup file, packaged-web proof, and TUI-scale proof. The
other 66 fast/core `BabysitterDryRunEnvTest` cases remain local and
coverage-included.

**CI contract:** The workflow runs the new files as separately named
`multi-agent setup integration` and `babysitter dry-run security matrix`
matrix legs. The existing protected `rake test (Ruby 3.4)` aggregator remains
fail-closed over exhaustive coverage and the complete expensive-gate matrix, so
all four outer proofs must pass before merge without adding branch-protection
contexts that older branches cannot produce. Each generated gate also requires
at least one non-skipped test with an assertion, so an emptied file or stale
filter fails instead of reporting a false green.

**Agent workflow:** Run the setup-agents or babysitter gate locally only while
diagnosing its CI check. During normal implementation, use the smallest focused
tests for changed behavior and one broad default-suite checkpoint when
warranted.

**Focused verification:** The generated setup gate completed 5 runs and 26
assertions in 56.123 seconds. The filtered babysitter gate completed its single
matrix test with 1,376 assertions in 41.293 seconds; the remaining core file
completed locally in 16.317 seconds with one intentional gate skip. Comparing
the isolated before/after file timings removes about 111 seconds from the normal
suite. A focused coverage run keeps all 108 executable
`lib/hive/babysitter/dry_run_env.rb` lines covered; hosted exhaustive coverage
remains authoritative for the whole repository.

**Hosted coverage follow-up:** The first exact-head coverage run identified 25
`AgentSkills::Inspector` lines that had been covered only incidentally by the
setup integration file. Fast unit coverage now owns the native Codex/Pi
inventory, marketplace-source conflict, and package-version paths explicitly;
the setup integration proof remains isolated in its named gate.
