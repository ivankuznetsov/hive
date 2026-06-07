## [2026-06-07T16:31:33Z] wiki — audit hv candidate version-gate coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `f1910de4` changed `bin/hv` and `test/unit/hv_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hv candidate version gate fallback Apache Hive"` surfaced the existing `hv` CLI/gap/log coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `bin/hv`, `test/unit/hv_test.rb`, README/install references, [[cli]], [[operating]], and [[testing]]. Confirmed existing command/API pages already document the strict bare `X.Y.Z` candidate gate and version-valid `HIVE_BIN_OVERRIDE` behavior; updated [[gaps]] to carry forward the missing live-smoke evidence for installed `hv` wrappers that encounter version-invalid XDG/Homebrew/custom candidates. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]
