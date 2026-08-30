---
title: Action Cable stream lifecycle ownership
date: 2026-08-30
tags: [web, action-cable, solid-cable, concurrency, testing]
---

`StatusChannel` now owns one coordinated boundary across `stream_from`,
`stop_stream_from`, and `stop_all_streams`. Pending attempts remain outside
Rails' stream registry, queued cancellation makes no raw adapter unsubscribe,
registration completed after stop receives one event-loop cleanup, and only a
live successful registration can confirm or deliver. Failure clears stream and
pending state before releasing the broadcaster lease and requesting one
reconnect.

Deterministic barriers prove both teardown windows against an explicit
unfenced Rails negative-control channel. A mechanism-neutral contract uses a
real `ActionCable::Connection::Base` and channel for default transmit,
callbacks/blocks, coders, stop APIs, teardown, injected failure, recovery, and
empty final state. It passed with the real Async adapter and with Solid Cable
`4.0.0` against a temporary SQLite database loaded from `db/cable_schema.rb`;
the Solid suite also proved listener, connection, row, and database cleanup.
The focused browser file passed 30 cases / 222 assertions and records the
disposed-source confirmation before server teardown with no catch-up action or
later confirmation.

One-time acceptance ran both controlled race windows 100 times with
`STATUS_CHANNEL_STRESS_SEED=42837`: 25 tests / 1,935 assertions completed with
no failures, errors, or skips. Normal focused execution leaves stress disabled.
The current dependency remains released Rails/Action Cable `8.1.3.1`; no
Gemfile or lockfile changed. The dependency page records the private API guard,
current coordination rollback, and exact provenance plus atomic rollback
required before any future framework handoff.

Release-default broad verification passed 344 Web tests / 2,055 assertions and
63 system tests / 636 assertions; RuboCop was clean. The standalone golden path
did not reach its PR gate in two attempts because its unchanged baseline
fixture fakes Claude but routes mandatory plan review to a real Codex process,
which remained active past the E2E's 90-second bound. That non-isolated
baseline gate is recorded in `wiki/gaps.md` rather than reported as passing.
