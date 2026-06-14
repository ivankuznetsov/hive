## Web: audit golden-path E2E stale-row coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `18333735` changed `web/test/e2e/golden_path_e2e.rb` and already added `wiki/testing.md` coverage plus `wiki/log.d/20260614-180312-golden-path-e2e-stale-row-click.md`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "golden path e2e stale row Turbo task link"` had no indexed hits, and the configured master wiki only had generic Turbo context. Verified the committed diff and current golden-path E2E source. Refined [[testing]] to match the helper's exact retry boundary (`Capybara::ElementNotFound` row-lookup windows and Playwright "not attached to the DOM" click failures), updated [[commands/web]] so its test summary includes the explicitly-run golden-path E2E, and carried the new commit plus remaining hosted/live evidence uncertainty into [[gaps]]. Page coverage count did not change, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[commands/web]]
- [[gaps]]
