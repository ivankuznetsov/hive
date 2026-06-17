## [2026-06-17T01:30:55Z] wiki - audit unusable e2e replay coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `6ce31190` changed `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, and existing e2e wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes handlers commands executable entrypoints README command API surface"` surfaced prior wrapper/e2e refreshes, and the configured master wiki path only had general route/API coverage guidance. Inspected the committed diff plus current `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[e2e]], [[testing]], and [[gaps]]. Updated [[e2e]] so the replay JSON contract explicitly distinguishes `missing_repro` from `unusable_repro`, updated [[testing]] to name missing and non-executable replay artifact validation, and carried the remaining uncertainty forward in [[gaps]]: no checked-in artifact proves a real retained failure bundle lost executable mode before replay, and no live patrol/babysitter wrapper consumption of the e2e JSON surface was found. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
- [[gaps]]
