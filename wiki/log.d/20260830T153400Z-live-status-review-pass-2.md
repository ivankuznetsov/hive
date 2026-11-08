---
title: Live-status review pass 2 lifecycle closure
date: 2026-08-30
tags: [web, turbo, action-cable, lifecycle, review]
---

The second stage-6 fix pass closed detach/attach predecessor custody, retry-
timer synchronous failure handling, message callback fencing, unconfirmed
failure ordering, and successor-setup error reporting. Plain DOM detach now
registers the same bounded retiring owner as attribute supersession, so three
or more rapid unconfirmed detach/attach cycles remain capped at two dedicated
transports.

The focused browser suite restores the deleted immediate detach/reattach
interleaving and real client-side recovery evidence. Dedicated consumer setup
rejection and a throwing Action Cable `connection.open` both recover through a
fresh consumer and complete a real `StatusChannel#catch_up`; a persistently
throwing Turbo registration remains in `retry_wait` with an owned timer until
the seam recovers. Message delivery failures now use the same owner/attempt
fence as the other Action Cable callbacks.

Verification obtained for this pass:

- `mise x ruby@3.4.7 -- bundle exec rails test
  test/system/status_stream_source_test.rb` from `web/`: 27 runs, 292
  assertions, 0 failures, 0 errors, 0 skips.
