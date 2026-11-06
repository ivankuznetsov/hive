# Keep incomplete task creation from crashing the daemon

A live patrol-fix task had null IDs in both meta.yml and its creation receipt.
The dispatcher passed that missing identity into strict attempt admission, which
raised `attempt task subject has incompatible identity with legacy fields`.
The exception escaped the scheduler and repeated service restarts reached
systemd's start limit.

Admission now returns `missing_task_identity` before observing or writing the
task source. The daemon logs an identity-specific deferral and continues other
work. The record validation stays strict and no existing task IDs are rewritten.
A real-store dispatcher regression reproduces the original exception and checks
that missing-ID admission writes no attempt and a valid task can still launch.
