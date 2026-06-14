---
date: 2026-06-14
slug: golden-path-slug-helper
pages: [testing]
---

Fixed the hosted web CI failure on PR #469's `hivebox web (Rails tests +
system)` job after the golden-path E2E raised `NameError: undefined local
variable or method 'task_slug'` at `web/test/e2e/golden_path_e2e.rb:131`.
The previous golden-path stabilization added `task_slug_from_grid!` but left
the call site wired to a nonexistent `task_slug` helper. The test now captures
the slug from the current status-grid DOM before clicking through to the task
page, then reuses that captured slug for `wait_for_answer_window!`.

Refreshed [[testing]] so the documented convention matches the current source:
the E2E reads the slug from the current grid, still retries the live row click
when Turbo detaches it, and uses the captured slug only for the daemon
answer-window and mtime-baseline guard. Verified locally with
`cd web && bin/rails test test/e2e/golden_path_e2e.rb` and
`bundle exec ruby -Itest test/eval/support/reporter_test.rb`.
