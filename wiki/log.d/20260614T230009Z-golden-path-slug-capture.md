---
date: 2026-06-14
slug: golden-path-slug-capture
pages: [testing]
---

Fixed the Hivebox golden-path E2E after the current `main` merge introduced an
undefined `task_slug` call before the daemon answer-window wait. The test now
captures the slug with the existing current-DOM grid helper before clicking
through to the task page, then reuses that saved slug for
`wait_for_answer_window!`.

Updated [[testing]] so the documented golden-path flow matches the code: the
slug lookup happens on the grid before task-page navigation, avoiding retained
Capybara row elements while still giving the daemon wait the real task slug.
Verified with:

- `cd web && bin/rails test test/e2e/golden_path_e2e.rb`
- `cd web && bin/rubocop test/e2e/golden_path_e2e.rb --format simple`
- `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`
