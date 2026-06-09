## [2026-06-08T21:37:18Z] wiki - audit e2e single JSON contract coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `96242e97` fixed duplicate successful JSON output from `bin/hive-e2e`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hive-e2e duplicate JSON documents"` surfaced prior e2e executable coverage, and the configured master wiki path added no project-specific constraints. Inspected the committed diff plus current `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[e2e]], [[testing]], [[commands]], and [[gaps]]. Confirmed the committed [[e2e]] update documents the single-document stdout contract, then refreshed [[commands]] and [[testing]] so the interaction-surface and test-contract pages also say successful `list --json` / `clean --json` outputs are one parseable JSON document. Recorded the remaining uncertainty that no in-tree artifact shows a live patrol/babysitter wrapper consuming those e2e JSON surfaces after the fix. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands]]
- [[testing]]
- [[gaps]]
