---
title: Identity-fenced teardown for dedicated retry resources
date: 2026-08-30
category: architecture-patterns
module: hive
problem_type: architecture_pattern
component: architecture
severity: high
applies_when:
  - "an asynchronous setup attempt owns a socket, subscription, timer, or other retryable resource"
  - "release ordering matters because acquire and release execute independently"
  - "cleanup must continue after one operation fails without losing the first error"
related_components:
  - web/app/javascript/status_stream_source.js
  - web/test/system/status_stream_source_test.rb
tags:
  - lifecycle
  - cleanup
  - identity-fence
  - retry
  - action-cable
  - turbo
---

# Identity-fenced teardown for dedicated retry resources

## Context

Hive's live status source used to recover through turbo-rails' shared Action
Cable consumer. That made ownership ambiguous: teardown had to inspect shared
subscription state, and a late callback or queued reconnect could act after a
new logical owner existed. The replacement gives every application attempt a
dedicated consumer and transport, while transport-level reconnect remains on
the same attempt.

Dedicated resources make the cleanup edge explicit, but they also make three
rules non-negotiable: retired asynchronous work must be inert, an unconfirmed
release may require transport-before-handle ordering, and one cleanup failure
must not prevent the remaining resources from being released.

## Pattern

1. **Fence every continuation with object identity.** Keep one current attempt
   object on the owner. Callbacks, timers, resolved promises, and wrapped
   `open`/`reopen` functions proceed only while that exact object is current,
   mounted, and not retired. Retirement clears the current slot before running
   external cleanup, so re-entrant work sees a closed boundary.
2. **Capture resources at the moment they can appear.** A connection can assign
   a socket and then throw. Record the socket in `finally`, not only after a
   successful `open` or `reopen`, so teardown can still reach the partially
   created transport.
3. **Detach private slots before calling external code.** Copy the subscription,
   consumer, connection, socket, and monitor to local variables, then null the
   attempt's fields. Repeated cleanup and late callbacks cannot rediscover and
   operate on those resources.
4. **Make ordering a named policy.** Confirmed subscriptions unsubscribe before
   transport shutdown. An unconfirmed, timed-out or stale registration closes
   its dedicated transport first so unsubscribe cannot overtake the server's
   pending subscribe job.
5. **Collect cleanup failures and preserve the first.** Run every applicable
   operation through a collector. Direct lifecycle calls rethrow the exact
   first value only after terminal state is committed; DOM and async boundaries
   warn after their successor and presentation obligations finish.
6. **Bound predecessor custody.** Supersession may retain one unconfirmed owner
   briefly. Before a second supersession allocates another successor, force the
   older predecessor through transport-first retirement so live allocation
   remains capped at predecessor plus current.

## Why this works

The attempt object becomes both the ownership record and the cancellation
token. No global registry or shared-client scan is needed, and cleanup decisions
cannot accidentally affect another source. Clearing fields before side effects
makes teardown idempotent under re-entrancy. The collector separates cleanup
completeness from error reporting, while the explicit ordering option documents
the one race that ordinary release-first cleanup would reintroduce.

## Verification

Exercise more than isolated counters. The focused browser suite should cover:

- real server lease acquisition and release around pre-confirmation detach;
- the bounded no-confirmation timeout with server-observable zero subscribers;
- a socket assigned immediately before `open` throws;
- callbacks arriving after timeout or retirement;
- retry restoring both the external listener and same-URL recovery latch;
- repeated supersession never exceeding two owned transports;
- immediate detach/reattach while consumer setup is pending;
- persistent synchronous retry failure remaining armed until recovery;
- real catch-up after client-side setup and partial-registration failure;
- cross-URL navigation replacing one transport and detach returning to zero.

This pattern applies beyond Action Cable wherever an attempt owns a dedicated
lease or transport and asynchronous acquisition can race retirement.
