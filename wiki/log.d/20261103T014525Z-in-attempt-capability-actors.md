---
title: Bound capability actors to their parent attempt
created: 2026-11-03
tags: [capabilities, attempts, routing, permissions]
---

Added reusable capability sub-spawns under a real running parent attempt, with
separate spawn/session correlation and exact accepted actor, route, runtime,
skill and approval checks. Parent lease and fleet/task reservations remain
single; live child account occupancy participates in atomic account admission.
Cancellation waits for launcher completion and identity-fenced process cleanup.

Shared stage sessions clamp specialist and primary resources, settle only
observed spending, and release reservations for proven prelaunch denials.
Specialists contribute bounded guidance to existing plan and execute prompts.
Security approvals explicitly pin configured accounts and launch bindings, and
accepted policy retains immutable unselected guidance templates for later
proposal comparisons.

The actual Claude policy hook validates commands before wrapping its Bash tool
in Hive's existing strict read-only, no-network command sandbox. Offline tests
execute an approved local fixture and prove outside-file, host-network and
environment denial. Live Claude sandbox nesting remains untested and must fail
visibly without an unsandboxed escape. Direct specialist execution requires a
durable parent. Feature adoption remains disabled pending the remaining gates.
