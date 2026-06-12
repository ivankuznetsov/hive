---
date: 2026-06-11
slug: grid-scroll-preserve
pages: [commands/web, gaps]
---

Operator-reported: grid updates on `/` yanked the page back to the top. The
status channel's refresh signal (added for task pages) also reaches the
index, which had no morph metas — Turbo fell back to a full-body replace
refresh, resetting window scroll. The index now carries the same
`turbo-refresh-method=morph` + `turbo-refresh-scroll=preserve` metas, and
the composer form is `data-turbo-permanent` (it holds typed-but-unsent idea
text and staged image chips — Stimulus state a morph cannot re-render).
System test pins scroll position and composer text across a live broadcast.

Also recorded in [[gaps]]: the review fix phase does not detect agent loss
when the tmux server itself dies (observed during the third
sweep-kills-server incident, this one from a pre-fix long-running child;
recovery is TERMing the review parent so the daemon re-dispatches).
