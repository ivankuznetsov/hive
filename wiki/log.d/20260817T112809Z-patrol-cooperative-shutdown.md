# Patrol honours SIGTERM instead of running until SIGKILL

The daemon stops by SIGTERMing children and waiting `shutdown_grace_sec`
(600 by default) before SIGKILL. Every other long-running child traps TERM —
`attempts/supervisor`, `bot/supervisor`, `daemon/dispatcher`, `commands/watch`,
`tui/app`, `tui/subprocess`, `web/supervisor`. Patrol did not.

Measured on this host: `systemctl --user restart hive-daemon` at 12:08:10
stopped at 12:18:12 — 602 seconds, the full grace — and systemd then reported
"Unit process ... remains running after unit stopped". Patrol kept starting new
feature scans throughout. A forced kill is what can strand an effect between
prepare and settlement, and `prepared` is the state recovery handles worst.

`Hive::Patrol::Shutdown` is a cooperative flag installed by `commands/patrol`.
It is only consulted where nothing is in flight:

- `Reviewer#call`, between features. The reviewer is a pure producer, so the
  findings already produced are kept and the rest wait for the next cycle.
- the fix-candidate loop, before `perform_fix_attempt`, so no effect has been
  prepared for that finding.

Refusing to start new work cannot strand an effect; it is strictly less work.
No existing state transition changed.

See [[modules/patrol]].
