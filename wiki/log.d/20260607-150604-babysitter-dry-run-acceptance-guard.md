## [2026-06-07T15:06:04Z] babysitter — fail-closed dry-run acceptance PATH guard

**Action:** Hardened `test/babysitter/acceptance/dry_run_test.rb` so the fake dry-run agent prepends temporary failing `git` and `gh` guard binaries before `Hive::Babysitter::PrFixer.run`. The babysitter dry-run stubs still skip the mutating force-push, PR comment, and PR close commands, but any PATH overlay regression now resolves to the local guard instead of the machine's real GitHub or Git CLI. Refreshed [[testing]] to record the acceptance fail-closed coverage. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
