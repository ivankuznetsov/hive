# 2026-09-25 — Linux quiescence custody remains fail closed

- The execution host's unified cgroup v2 hierarchy accepts a transient
  `systemd-run --user --scope --property=Delegate=yes` attempt scope, but the
  same unprivileged user can write the parent `app.slice` cgroup boundary.
- A real scoped workload moved its PID into a sibling cgroup; its
  `/proc/self/cgroup` entry changed from the attempt scope to that sibling.
  Fork, reparenting, or `setsid` therefore cannot turn this scope into durable
  installation custody.
- `ProcessCustody::LinuxCgroupV2` now rejects a writable parent directory as
  well as a writable parent `cgroup.procs`. The focused capability test covers
  both the rejected escape surface and the narrowly eligible synthetic shape.
- U2b/U6b are not qualified on this host. Active attempt roots continue to
  return `ownership_unverifiable`; the independently delivered increment-1
  idle-registry path is unchanged and no general Linux backup-readiness claim
  is made.
