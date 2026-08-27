# Stop replaying inert recovery work

**Action:** Recovery resume now returns persisted receipts immediately for
cooling requests and immutable operator-owned blockers.

**Reason:** A live daemon with 93 durable recovery requests spent more than a
minute reopening tasks whose requests were already parked as generation,
identity, or deterministic conflicts. Patrol admission could not run until the
whole historical queue had been replayed.

**Verification:** Added focused coordinator coverage proving inert blockers and
future cooldowns perform no task resolution. In the live queue, the 81 already
parked requests became receipt-only work instead of guarded task transitions.
