---
date: 2026-06-14
slug: golden-path-dom-race
pages: [commands/status, modules/daemon, testing]
---

Fixed a flaky golden-path hivebox E2E failure observed on PR #463's
`hivebox web (Rails tests + system)` job. The browser test added an idea,
stored the matched `.task-row`, and later clicked through that saved Capybara
element while the foreground daemon was already broadcasting Turbo replacements
for `#projects`. In CI, Playwright prepared the click after the row had been
detached, raising "Element is not attached to the DOM" before the task page
loaded.

The test now reads the task slug from the current DOM with one JavaScript query
and visits `/tasks/:project/:slug` directly before answering the brainstorm. A
follow-up CI run then exposed the adjacent mtime race: the answer could be
written in the same filesystem mtime second as the daemon's edit-resume
baseline, and `hive status --json` was truncating subsecond task mtimes before
`StatusConsumer` compared them with the daemon's persisted baseline. That left
the row at `2-brainstorm needs_input`. Status JSON now emits microsecond
`mtime` / `folder_mtime` values, and the E2E also waits for the daemon's
`needs_input` classification plus a distinct `brainstorm.md` mtime tick before
submitting the answer.

That keeps the golden-path coverage focused on the real browser, daemon,
brainstorm answer, stage advancement, and worktree commit behavior without
retaining a volatile grid element across live updates or collapsing/truncating
the operator answer relative to the daemon's baseline mtime. Updated
[[commands/status]], [[modules/daemon]], and [[testing]] with the convention.
