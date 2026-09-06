# Fresh artifact overlays discard stale host PID files

**Action:** A newly seeded project-command `tmp` overlay now removes and
recreates its `pids` directory before entering bubblewrap. Reusing that overlay
within the same capture does not clear it, so a server started by the current
attempt retains its live ownership file.

**Why:** Pi dogfooding copied an ignored Rails `tmp/pids/server.pid` containing
host PID `2` into a fresh PID namespace. Rails found its own namespace PID `2`,
reported that a server was already running, and every browser navigation failed
despite no project server being alive.

**Tests:** The project-command sandbox test seeds a stale source PID, proves the
fresh overlay drops it without mutating the worktree, and proves a later PID in
the shared attempt overlay survives reuse.
