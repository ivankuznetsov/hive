---
title: Server-rendered live project order
date: 2026-07-20
tags: [web, turbo, stimulus, status]
---

Live project ordering now has one rendering authority. `StatusBroadcaster`
sorts each snapshot once and broadcasts the project rail, composer selector,
and project grid from Rails partials. The project filter controller only owns
filter state; it no longer rebuilds or moves server-rendered DOM.

This removes a MutationObserver feedback loop caused by repeatedly moving the
same navigation buttons during every observer callback. The composer keeps its
selected project across a targeted Turbo morph when that option still exists,
preserving unfinished browser state without duplicating ordering logic.

Focused model coverage pins the broadcast targets and shared order. The
Playwright project-rail flow proves that live updates finish, reorder all three
surfaces, retain the active filter, and preserve the operator's selection.
