---
title: Bounded web polling and composer resources
date: 2026-07-22
tags: [web, stimulus, turbo, performance, uploads]
---

Timed Turbo-frame polling now treats the frame's `busy` / `aria-busy` state as
an ownership boundary. Interval ticks remain observable but do not call
`reload()` while an earlier request is in flight, preventing a slow log or
agent-login response from being continually cancelled and restarted.

The permanent new-idea composer now receives the server's eight-image and
10 MB-per-image limits as rendered Stimulus values. Paste and picker batches
accept only their bounded valid prefix, report oversize and overflow files in
an accessible status message, and rebuild the multipart `FileList` once after
the batch. The controller inspects at most 16 picker/clipboard entries even if
a synthetic list claims millions, and renders a generic attachment glyph rather
than decoding potentially gigantic image dimensions. This caps DOM, decoded
image memory, retained `File` objects, and the previous per-file `DataTransfer`
rebuild cost.

Stimulus disconnect now schedules a short cancellable cleanup: the same
`data-turbo-permanent` form can reconnect without losing staged files, while a
genuinely abandoned form clears both its attachment map and browser-owned
`FileList`. Puma's native `http_content_length_limit` rejects bodies above the
complete valid 81 MiB idea envelope before Rack parses or spools multipart
parameters. Hive's Puma hook rejects chunked request bodies at the parsed-header
boundary because Puma's decoder otherwise spools them without an incremental
limit, and closes that connection so unread chunks cannot be mistaken for a
later request. Controller count/size validation remains authoritative inside
the admitted envelope. The Puma-only hook lives in the Rails app's `web/lib`,
leaving the CLI gem's Puma-free, 100%-coverage source set intact.

Playwright coverage pins busy-frame pause/resume, mixed overflow/oversize
batches, million-entry synthetic-list inspection bounds, non-decoding chips,
preserved permanent reconnects, and true-disconnect cleanup. Rails integration
coverage pins controller count/size limits and Puma's declared-length and
chunked pre-Rack 413 boundaries. Validation completed with the full Rails suite
(225 runs / 1,143 assertions), the full Playwright suite (52 runs / 353
assertions), the final real-socket Puma suite (3 runs / 13 assertions), seven
changed Ruby files clean under RuboCop, clean JavaScript syntax checks, and zero
Brakeman warnings after the repository baseline.

**Links:** [[commands/web]], [[testing]], [[architecture]]
