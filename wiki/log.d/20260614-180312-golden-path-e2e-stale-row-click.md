## Web: stabilize golden-path E2E task-row click

**Action:** Updated `web/test/e2e/golden_path_e2e.rb` so the browser test no longer retains a `.task-row` element across the daemon/Turbo update window. The task link is re-resolved and retried only for the observed stale-row case where Playwright reports that the element is no longer attached to the DOM.

**Root cause:** The golden-path E2E asserts that the submitted idea appears in the status grid, then the daemon can advance the task from `1-inbox` to `2-brainstorm` and Turbo can replace the row before the saved Capybara node is clicked. The hosted web CI failure on PR #459 hit that exact stale element race at `web/test/e2e/golden_path_e2e.rb:119`.

**Verified:** `cd web && bin/rails test test/e2e/golden_path_e2e.rb` (twice); `cd web && bin/rubocop test/e2e/golden_path_e2e.rb --format simple`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[testing]]
