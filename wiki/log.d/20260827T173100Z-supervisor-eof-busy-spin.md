# Stop attempt supervisor busy-spin after output pipes reach EOF

**Change:** When every worker output pipe has reached EOF but the supervise
loop is still awaiting worker exit or a lingering process group, `Supervisor`
now sleeps the computed `wait_for` budget instead of skipping the blocking
call entirely. The select path for live pipes is unchanged.

**Why:** The loop's only sleep primitive was conditional on having readable
IOs. With both output pipes at EOF, `IO.select` was skipped, the
`Process.wait2(WNOHANG)` poll had no blocking call, and one supervisor core
spun at ~100% CPU for the remaining lifetime of the worker (measured at CPU
ratio 0.99 over a 3-second idle worker; 0.01 after the fix).

**Safety:** The budget is still clamped by heartbeat, timeout, termination,
and post-exit deadlines, so signal cancellation and timeout enforcement keep
their existing worst-case latency (at most one budget slice, 50 ms by
default). Output draining, reaping, lingering-group termination, and terminal
receipt behavior are unchanged. Regression coverage pins elapsed time and
process-CPU ratio in `test/unit/attempts/supervisor_test.rb`.
