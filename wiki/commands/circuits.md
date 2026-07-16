---
title: Provider circuit inspection and administrative clear
type: command
created: 2026-07-16
---

# `hive circuits`

`hive circuits [list] [--json]` reads global provider/model circuit state in
stable provider/model order. It reports adapter, state/reason, timed versus
indefinite retry, probe owner, observed durable attempt count, configured cap,
generation, and last transition. An absent cap is rendered as `unlimited`, not
zero. JSON validates against `hive-circuits.v1` and contains no raw provider
output.

`hive circuits clear PROVIDER [--model MODEL] --reason TEXT` performs a locked
manual close and appends the actor/reason to the sanitized global circuit audit.
The target must already exist in durable circuit state. Clearing changes only
future eligibility; it does not edit task markers or preempt running fallback
work. A daemon tick can subsequently re-offer parked work to the router.

## Backlinks

- [[modules/config]] · [[modules/daemon]] · [[modules/events]] · [[state-model]]
