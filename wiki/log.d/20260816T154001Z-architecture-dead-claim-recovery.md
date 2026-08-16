# Architecture Patrol recovers dead claims before lease expiry

Architecture Patrol now treats its two-hour discovery lease as a live-worker
fence rather than a mandatory restart delay. After a daemon restart, the new
daemon uses the recorded PID, process start time, and process group to surface
an attached worker that has already exited, then rechecks and supersedes that
claim under the existing generation CAS. Live, reused, missing, or
uninspectable process identities remain fail-closed. The same proof permits a
saturated occurrence to roll without waiting for the abandoned lease.
