# Re-arm durable attempt claims at the wrapper handoff

Durable attempt admission now re-arms the persisted launching record's claim
deadline immediately before invoking the detached wrapper launcher. Task
activity and context-provenance capture remain prelaunch so they observe the
unmodified worktree, but their latency can no longer consume the wrapper's
claim window.

The re-arm is a lease compare-and-swap on the same launching attempt. It keeps
the immutable admission timestamp, records `handoff_armed_at`, and refuses a
record that was concurrently claimed or reconciled. A focused regression
advances the wall clock by 45 seconds during context capture and proves the
30-second claim window begins afterward.
