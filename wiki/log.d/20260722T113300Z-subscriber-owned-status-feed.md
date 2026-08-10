---
title: Subscriber-owned status feed
date: 2026-07-22
tags: [web, performance, turbo, action-cable]
---

Hive web no longer scans every registered project merely because the Rails
server is running. A dedicated `StatusChannel` starts the shared
`StatusBroadcaster` when the first status or task page connects and stops it
after the last page disconnects. Multiple pages still share one poller.

The synchronous page snapshot now primes that poller, so opening a page does
not immediately repeat the same full-fleet scan when Action Cable connects.
Only the first request may claim an idle baseline; a competing request cannot
replace what that page rendered. Each render nevertheless receives a canonical
SHA-256 token for its own semantic payload. After its Action Cable subscription
is confirmed, a current page does nothing and a stale or competing page gets
one targeted Turbo refresh. Tokens are stable across Puma workers and process
restarts, while timestamp-only ticks leave them unchanged. That targeted
stream names the page token; the permanent source carries the token and URL in
a live-element property through the same-URL Turbo move, then consumes that
handoff into the active connection. Because Turbo snapshot clones do not copy
JavaScript properties, history restoration after a source-less route cannot
revive an older attempt. Later confirmations cannot loop reconciliation GETs,
navigation cannot revive a consumed handoff from another URL, and a real socket
disconnect releases the connection-local attempt for later recovery.
The feed retains only the payload and counters, avoiding an unused
full-registry JSON serialization on each render. Baseline claims are released
when a page never reaches Cable, and shutdown cannot erase a newer claim that
wins while the detached poller is joining.

While subscribers are present, the scan cadence is five seconds rather than
one second; the full snapshot is still computed fresh for every HTTP render,
and filesystem changes continue to trigger Turbo refreshes after polling.
The poller carries its comparable key with each published payload and reuses
the prior token for unchanged content, so each tick normalizes once and only
changed semantic content pays canonical JSON serialization and SHA-256 work.

The Cable stream source is a permanent, Hive-owned custom element backed by
Turbo's signed stream contract. Its asynchronous connection is cancellation-
safe: a handle whose owner detaches before confirmation is released from the
confirmation callback, after server registration, so Action Cable's worker pool
cannot reorder unsubscribe ahead of subscribe and strand a channel. Confirmation
belongs to the current WebSocket transport rather than the subscription's
lifetime: disconnect clears it, so teardown during a reconnect again waits for
that transport's confirmation, rejection, or disconnect. If none arrives within
five seconds, Hive closes the otherwise-unowned Cable transport to give the
server an authoritative cleanup edge before forgetting the local handle. The
channel fences Rails' deferred adapter registration before it starts and again
when it confirms; a registration that finishes after socket teardown
immediately unsubscribes itself instead of surviving the earlier cleanup. If
the deferred adapter call raises, the channel releases its poller lease and
closes the transport with reconnect enabled rather than remaining active but
unconfirmed. A
rejected subscription is forgotten by Action Cable and retried by Hive; a
rejected asynchronous consumer setup likewise retries every five seconds
without DOM churn. Hive first clears turbo-rails' cached rejected consumer
promise so the retry can create a real consumer; disconnect clears the timer
before it can create a subscription. A synchronous create failure also removes
the partial Action Cable registration and replaces the failed consumer. The confirmed subscription
performs the token handshake directly; the previous reconnect MutationObserver
is gone, and a fresh Turbo
navigation is pinned to one request. StatusBroadcaster renders the refresh and
both targeted project surfaces into one message before one Cable send, so a
partial render failure cannot deliver a refresh prefix and retry it into an
HTTP loop. The same-URL handoff is scoped to the refresh cycle rather than the
old rendered token, so a reconciliation GET that legitimately returns a new
token still reports the prior attempt and remains bounded to one request.
Failed broadcasts remain pending across last-subscriber shutdown. Broadcaster
shutdown joins its owner thread before looking up and stopping the lazily
installed nested feed, closing the rapid-connect race. If the first poller
thread cannot be created, lease acquisition restores the prior subscriber count
and the channel rejects the subscription so the browser can retry cleanly.
Signed-stream verification and lease acquisition both finish before
`stream_from` queues pub/sub registration, so that rejection cannot race a late
handler into the adapter after Action Cable cleanup.
Tests cover accepted/rejected subscriptions, first/last subscriber behavior,
teardown during barrier-paused stream verification, idempotent concurrent
cleanup while another channel remains active, unchanged-token reuse,
competing snapshot priming, content-token late-page catch-up across independent
feed instances, a one-refresh cross-worker lag bound with disconnect and
cross-navigation release including pending, failed-send, and source-less
history round trips, delayed/rejected client setup, poisoned-cache
recovery, partial-registration cleanup, confirmation-ordered cancellation,
transport-scoped reconnect teardown, bounded never-confirmed cleanup, server
startup rejection recovery without queued stream work, retry cancellation,
late adapter-registration cleanup, deferred adapter-failure reconnect,
failed-send confirmation
retry, shutdown overlap, all-or-nothing rendering, retry after
broadcast failure and reconnect, server-latched one-request fresh navigation,
and both status and task page wiring. Token equality is exercised in separate
Ruby processes and remains bound to top-level SHA-256 even when another Hive
component defines `Hive::Digest`; request-count assertions wait beyond Turbo's refresh debounce,
and the browser lifecycle covers the real subscription callbacks plus a
same-token Board/task/Board round trip plus Board/Repos/history restoration and
a changing-token reconciliation cycle.
The task status owner wraps all task mutation forms so the
native submission guard cannot miss them. Admission begins at
`turbo:submit-start`; cancelling a confirmation therefore cannot retain a
phantom in-flight form and suppress later refreshes. Shared-scan tests use
explicit barriers, bounded waits, exact scan counts, and prove recovery from an
initial empty fallback. Live
browser profiling against the real 15-project, 81-task registry showed zero
DOM mutations and zero HTTP requests in every open status tab during each
20-second idle window. Browser main-thread task time was 0.0048 seconds for one
tab and 0.0017--0.0158 seconds per tab with four open. The shared server poller
used 2.16 CPU seconds (10.8% of one core) for one tab and 1.56 seconds (7.8%)
for four tabs, rather than scaling with tab count. With no subscriber it used
0 CPU seconds over 10 seconds; after the last tab closed it used 0.01 seconds
(0.1%), proving poller shutdown. Warm server RSS settled near 193 MiB and each
Chromium page held roughly 2.5--3.3 MiB of JavaScript heap. This profile ran
from the worktree on an isolated port and config; the installed service was not
restarted or upgraded.
