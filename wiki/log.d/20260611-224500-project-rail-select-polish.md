---
date: 2026-06-11
slug: project-rail-select-polish
pages: [commands/web]
---

Operator-requested grid navigation: a left project rail (TUI left-pane
parity) filters the task list client-side — "All projects" plus one button
per registered project. Buttons, not links: a navigation would discard the
permanent composer's typed text. The choice mirrors into `?project=` via
history.replaceState, and a MutationObserver re-applies the filter after
each broadcast replace/morph (the replace drops client-set hidden
attributes). System test covers filter, URL sync, survival across a live
broadcast, and restore via "All projects".

Composer select polish: the "Project…" prompt no longer appears as a
selectable row (disabled+hidden placeholder via select_tag — FormBuilder
insists on injecting a blank option for required selects), and selects get
a custom chevron with right breathing room (native arrows hug the edge).
