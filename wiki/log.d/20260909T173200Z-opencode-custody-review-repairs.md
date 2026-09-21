# OpenCode custody review repairs

PR #1172 review against current main found three lifecycle races. The PR-author
completion probe now treats partial JSON as unfinished while final parsing stays
strict. OpenCode cleans invocation descendants after its native child exits and
before draining inherited stdout/stderr, preserving output emitted during cleanup.
Custody confirms token and PID/start-time ownership across two inventories before
signalling, protecting both procfs and the ps fallback against PID replacement
between the environment read and identity capture.

Focused regressions reproduce partial draft writes, PID replacement in both
inventories, and a real native fixture whose reparented setsid child retains both
capture writers and emits its final diagnostic on TERM. The wiki now explicitly
records that unreadable same-user environments cannot prove invocation ownership;
this remains cooperative lifecycle cleanup, not hostile-process containment.
