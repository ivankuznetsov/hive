## [2026-07-23T03:15:23Z] test - isolate dispatcher display-name backfills

**Action:** Changed the generic `daemon/dispatcher_test.rb` construction helper to install an inert display-name backfiller. Missing display names are common incidental fixture state in this routing suite; the production collaborator turned 59 of those rows into detached `hive generate-name` subprocesses across 197 tests, creating unrelated process/agent work. The dedicated `display_name_backfiller_test.rb` suite and the dispatcher's explicit wiring and defensive-rescue cases still exercise the real collaborator contract.

**Coverage:** The dispatcher suite passes at seed `45012` with 197 runs and 663 assertions, and the dedicated backfiller suite passes at the same seed with 18 runs and 71 assertions. Updated [[testing]] with the isolation boundary. No production behavior changed and no new uncertainty was introduced.
