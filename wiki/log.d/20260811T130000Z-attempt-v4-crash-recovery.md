## Reconcile crashed v3 attempts during the v4 cutover

The attempt layout migration no longer waits forever on a live-shaped record
whose owner definitively crashed. While every source writer lock is held it
marks expired pre-heartbeat launches and running attempts with a missing or
mismatched process identity as lost, then includes those records in the normal
v4 corpus/parity proof. Active or unverifiable owners still block the cutover.
The migration result reports the bounded `recovered_live` count.
