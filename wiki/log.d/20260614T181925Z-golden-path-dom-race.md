---
date: 2026-06-14
slug: golden-path-dom-race
pages: [testing]
---

Fixed a flaky golden-path hivebox E2E failure observed on PR #463's
`hivebox web (Rails tests + system)` job. The browser test added an idea,
stored the matched `.task-row`, and later clicked through that saved Capybara
element while the foreground daemon was already broadcasting Turbo replacements
for `#projects`. In CI, Playwright prepared the click after the row had been
detached, raising "Element is not attached to the DOM" before the task page
loaded.

The test now reads the task slug from the current DOM with one JavaScript query
and visits `/tasks/:project/:slug` directly before answering the brainstorm.
That keeps the golden-path coverage focused on the real browser, daemon,
brainstorm answer, stage advancement, and worktree commit behavior without
retaining a volatile grid element across live updates. Updated [[testing]] with
the convention.
