# OpenClaw creator proof gains an independent containment root

- Moved Linux child-subreaper and final-teardown authority from the expendable
  containment owner into a separate outer root.
- Added typed parent/root and root/owner framing, owner stop/exit monitoring,
  caller-cancel/EOF handling, and generational direct-child draining that does
  not retain PIDs across reap.
- Added adversarial coverage for owner death before readiness, partial and
  provisional result frames, owner `SIGSTOP`/`SIGKILL`, root setup failure,
  caller disappearance, and escaped `setsid` double-forks.
- Extended retained teardown evidence with
  `teardown_authority=independent_root` and
  `root_loss_guarantee=not_claimed`, and made both the attestor and verifier
  reject drift in those fields.

This closes the owner-death gap without claiming cleanup after containment-root
loss or for tasks stuck in uninterruptible Linux `D` state.
