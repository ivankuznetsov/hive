---
date: 2026-06-12
slug: pr-review-remediation-3
pages: [commands/web, commands/drop, modules/daemon]
---

External ce-code-review pass on PR #300 (4×P1, 4×P2), all addressed:

- Installers bind 127.0.0.1 by default (HIVEBOX_BIND opt-out): a fresh
  box is claimable by its FIRST login, so it must not be reachable by
  network peers before the owner signs in.
- require_login re-checks the CURRENT owner each request: rotating
  web.github.owner (or re-claiming) evicts old sessions, which hold
  repo-scoped tokens.
- hive-drop schema bumped to v2 for the pr_closed semantic change
  (true = PR cleanup clean incl. no-PR case); v1 file kept for pinned
  external validators.
- Web clone! runs in its own process group with a hard deadline
  (HIVEBOX_CLONE_TIMEOUT_SEC, default 180s) and removes partial targets —
  a wedged gh can no longer hold a Puma worker forever.
- Queue-grammar rejections of dispatchable names surface as typed 422s.
- The polled log tail reads a 256KB byte window, not the whole file.
- EVERY 3-plan heal requeues the rerun (limits_reached cooldown left the
  same markerless empty plan.md as agent loss).
- Compiled wiki/log.md restored to main; fragments only in the PR.
