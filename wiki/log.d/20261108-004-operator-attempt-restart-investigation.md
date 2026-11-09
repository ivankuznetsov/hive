---
title: Bounded operator-attempt restart characterization
date: 2026-11-08
---

No live-attempt orphaning reproduced in the exercised boundaries. No service
policy, lease timeout, reconciler or healer production behavior was changed.

Platform: Linux 7.2.15-1-omarchy x86_64, Ruby 3.4, user systemd available.
`test/integration/operator_attempt_restart_test.rb` uses a real supervisor,
real transactional attempt admission, an isolated task lease and deterministic
stage worker outside disposable service cgroups. The service processes are
sleeping placeholders with kill policies read from the shipped templates;
they are not the installed Hive daemon, Rails web or babysitter applications.

| Shipped service policy | Direct execute attempt | Attached review retry |
| --- | --- | --- |
| daemon: `KillMode=process` | pass | pass |
| web: default `control-group` | pass | pass |
| babysitter: `KillMode=mixed` | pass | pass |

Each disposable service changed MainPID on restart. The same attempt retained
matching wrapper and worker PID/start/session/group identities, its task lease
and identical working-marker bytes. A fresh reconciler with time advanced past
the heartbeat deadline retained the attempt as a capacity-reserving suspect,
with no new loss or successor. A fresh marker healer retained execute/review
markers while the worker held the task lease. Releasing each worker completed
one canonical successful attempt; the attached retry terminalized its recovery
request. The local probe captured six identity/lease/marker observations in an
ignored worktree artifact.

Verification:
`HIVE_TEST_SYSTEMD_RESTARTS=1 bin/test test/integration/operator_attempt_restart_test.rb test/unit/attempts/reconciler_test.rb test/integration/daemon_stale_agent_healing_test.rb`
passed 33 tests and 231 assertions. The unchanged reconciler tests also cover
missing/reused wrapper identity, unverifiable owners, launch deadlines and
terminal/interruption races. The opt-in process fixture disconnects SQLite
handles before forking and never restarts an existing operator service.

Inspected the supervisor's wrapper claim, worker process group and canonical
receipt; ProcessIdentity's PID/start/session/group matching; running versus
launching deadline rules; daemon startup/adoption, shutdown and marker healing;
babysitter signal/drain handling; web foreground/service lifecycle; and all
three service installers. Installers substitute executable/environment values
into the templates and do not introduce another KillMode. Daemon CLI stop
signals its verified PID; running-attempt reconciliation retains matching or
unverifiable wrappers despite heartbeat expiry. Marker healing separately
rechecks task leases before mutation.

Not exercised: restarting the three actual application services, installed
service drift, a production provider, historical incident logs, worker-only
survival across a real service failure, macOS launchd or other systemd/kernel
combinations. The existing caller-loss E2E scenario was inspected, not run.
The original report's cause remains unknown; this evidence does not claim a
service/platform-wide fix.
