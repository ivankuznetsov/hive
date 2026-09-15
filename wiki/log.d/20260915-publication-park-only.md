# Keep publication blocking separate from recovery

Removed publication-specific reopen actions, routing hints, carried-receipt
authorizations, and unrelated timing/finalization changes from the proposed
publication park. The retained contract records sanitized secret blocks,
shows the operator-owned state, and prevents repeated remote publication.
Regression coverage verifies there is no retry or rework action.

The receipt uses sanitized field names from the original scan and records the
Betterleaks policy version. Replays read the current publication result once.
Older recorded policy versions remain readable after scanner upgrades.
