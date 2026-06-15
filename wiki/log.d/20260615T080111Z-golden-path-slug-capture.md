---
date: 2026-06-15
slug: golden-path-slug-capture
pages: [testing]
---

Fixed the PR #480 `hivebox web (Rails tests + system)` failure in
`web/test/e2e/golden_path_e2e.rb`: the test called a nonexistent `task_slug`
helper after navigating away from the status grid, raising `NameError` before
the daemon answer-window wait could run. The test now captures the slug with the
existing current-DOM helper before clicking into the task detail page, then uses
that captured slug for the daemon log/mtime synchronization.

Verified locally with `cd web && bin/rails test test/e2e/golden_path_e2e.rb`,
`bin/rails test`, `bin/rails test:system`, and `bin/rubocop --format github`.
Updated [[testing]] to describe the capture-before-click contract.
