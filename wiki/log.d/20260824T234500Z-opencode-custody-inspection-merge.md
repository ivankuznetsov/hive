# Invocation custody and bounded export inspection compose

Detached-process custody and the bounded sanitized-export inspection landed on
separate branches that both rewrote OpenCode's wait loop, so integrating them
required deciding how the two bounds interact.

`wait_for_opencode_process` now carries the reusable `timeout_sec` and
`poll_interval` bounds the export inspection needs, plus the completion-probe
grace that stops a hung trailing turn once the controller output file is valid.
The probe is a keyword argument defaulting to the agent's own probe, and the
export inspection passes `nil` explicitly. That opt-out is load-bearing: the
inspection only runs after a successful run, so the run's output file is
already complete, and inheriting the probe would kill every export after the
grace window instead of letting it finish.

Custody cleanup runs before the capture threads are drained. Reaping the
descendants that inherited the run's stdout and stderr pipes is what lets those
readers reach EOF, so the ordering shortens the bounded drain rather than
competing with it; a capture the drain must still cut short is invalidated.

The 64 MiB export ceiling arrived from both directions and is one constant,
enforced on the export child through `rlimit_fsize` before it starts and again
when Hive reads the result.
