---
title: URL-addressed server-rendered project filter
date: 2026-07-22
tags: [web, rails, turbo, stimulus, kanban]
---

The Board/Grid project rail now uses ordinary GET links. `StatusController`
resolves `?project=`, renders only the selected project's markup, and redirects
unknown project names to the same canonical route without the stale filter.
Turbo refreshes that URL after a status broadcast, so HTTP remains the single
filter authority and unrelated project markup never enters the document.

The 96-line client filter controller is reduced to one progressive enhancement:
before Turbo follows an explicit project link, it selects that project in the
permanent composer so unfinished text and staged files retain the intended
context. The MutationObserver, animation-frame reapplication, History API
mutation, DOM hiding, active-class mutation, and view-form rewriting are gone.
The enhancement reads the raw data attribute rather than Stimulus's decoded
action parameter, keeping names such as `123` and `false` as strings, and
ignores modified, non-primary, prevented, and non-current-target clicks so a
new-tab gesture cannot retarget the current tab's unfinished idea. A bounded
Back/Forward event seam realigns the permanent composer only when browser
history restores a filtered URL, preventing the visible project and submission
target from diverging without clobbering choices during live morphs.
Rails renders active navigation state, deep-link composer selection, and
view-switch parameters. `StatusBroadcaster` now sends one complete refresh plus
composer-selector message and no longer maintains a separate project-rail
replacement.

Focused Rails, broadcaster, and Playwright validation is recorded in PR #833.
The completed checkpoint passed the full Rails suite (221 runs, 1,123
assertions), the full Playwright system suite on the former failing seed 20887
(50 runs, 328 assertions), and
three repeated Action Cable recovery runs at the hosted failing and boundary
seeds (9 runs, 30 assertions). The recovery fixtures now keep their replacement
socket alive until Rails observes the catch-up, and allow Action Cable's
jittered 6–12 second reconnect poll instead of racing the generic 10-second
Capybara wait. RuboCop and Brakeman remained clean.
Playwright examples now reset the registered project fleet inside the guarded
throwaway test root and prove Cable confirmation before one-shot filesystem
mutations. This removes test-order-dependent status scans and missed-update
races without changing production polling or reconnect intervals.
The remaining multi-client live-daemon smoke is retained in [[gaps]].

**Links:** [[commands/web]], [[architecture]], [[state-model]], [[testing]], [[gaps]]
