# Bound attempt bookkeeping contention

Introduced strict typed busy classification and one monotonic operation deadline
across admission, detached reservation, wrapper opening/registration, claim and
first heartbeat. Pre-start work has a positive finite 30-second configuration
budget and remains strictly inside persisted lifecycle expiry. Later heartbeat
and terminal writes retain their existing 600-second envelopes. SQL tries share
connection/fence work, reserve a positive wait, cap at one second and restore
connection timeouts. Failure measurements attribute connection/fence/SQL waits.

Supervisor schedules worker-registration and heartbeat retries in its existing
output/cancellation loop. Capability, identity and lease CAS remain authoritative;
matching live owners may repair a late claim, and ambiguous successful writes
are resolved from the stored winner. Exhaustion returns typed TEMPFAIL instead
of generic handoff failure; durable pending-operation recovery is a separate
follow-on seam.

Deterministic tests cover exact 30/600-second exhaustion, successful contention
beyond 30 seconds within the 600-second envelope, cyclic/wrapped errors and
unchanged nested deadlines. An independent SQLite holder delays claim by 2.2
seconds with bounded positive waits and one worker invocation; lifecycle and
launch-fence exhaustion stay bounded. A test first demonstrated that blocked
worker registration delayed stage timeout, then passed after retries moved
inside output/cancellation polling.
