---
timestamp: 2026-02-07T00:00:00Z
slug: loopback-read-failures-connection-fatal
tags: [screenote, oauth, loopback, bugfix]
---

## [2026-02-07T00:00:00Z] fix — Screenote loopback read failures are connection-fatal, not flow-fatal

**Action:** Fixed `Hive::Screenote::LoopbackServer#wait_for_callback`
(`lib/hive/screenote/loopback_server.rb`). Previously a per-connection read
failure raised straight through the accept loop: a browser/OS probe that
connected but sent nothing tripped the per-read deadline, the resulting
`Hive::Error` aborted the entire OAuth wait (only an `ensure`, no rescue), the
listener closed, and the real `/callback` redirect arriving afterwards was
lost. Additionally, once `IO.select` reported a socket readable, the old
blocking `socket.gets("\n", MAX)` could still block indefinitely on a slow-drip
client past the deadline.

Now every chunk of the request head is read via `select`-guarded
`readpartial`, so the deadline is enforced between chunks, and
`wait_for_callback` rescues per-connection read failures (`Hive::Error`,
`EOFError`, `IOError`, `SystemCallError`) around the head read: the offending
socket is closed, a warning is emitted, and the accept loop keeps waiting.
Only accept-level timeouts remain flow-fatal. Oversized headers likewise now
drop just the offending connection. Regression coverage added in
`test/unit/screenote/loopback_server_test.rb` (silent connect then real
callback; stalled partial request; oversized headers). Updated
[[commands/screenote]].

Uncertainty recorded in [[gaps]]: none known beyond timing-based tests using
short sleeps (kept generous margins).
