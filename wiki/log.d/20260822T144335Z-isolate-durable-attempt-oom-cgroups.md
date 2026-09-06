# Durable attempts leave the daemon OOM cgroup

**Action:** Moved Linux durable-attempt supervisors into one transient
systemd-user scope per attempt when the local user bus and `systemd-run` are
available. The scope preserves the caller environment and the existing
capability/ready descriptor handshake, but is a sibling of
`hive-daemon.service` instead of a descendant. Non-systemd hosts keep the
existing POSIX double-fork/session path.

**Why:** A live Webmail OpenCode review drove the shared daemon service cgroup
to 14.5 GB memory and 32.239 GB swap. systemd-oomd killed all 520 processes in
the unit, including the daemon, the accepted attempt supervisor, and its model
worker. `KillMode=process` protects ordinary restarts but cannot constrain an
OOM cgroup kill. The durable store preserved the patch and recovered the
attempt, but the same blast radius could recur on every large run.

**Evidence:** The focused launcher suite now exercises the exact prefixed
`systemd-run --user --scope` argv and inherited file descriptors. Its live
Linux test observes the claimed wrapper under
`hive-attempt-<digest>.scope`, distinct from the caller cgroup, and waits for a
successful terminal receipt.
