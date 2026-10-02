# 2026-10-02 — Launch Darwin native replay through an exact-inode hard link

- Hosted macOS proved that the kernel rejects native `execve` through
  `/dev/fd`, even after a fixed Bash child inherits the identity-checked
  `O_EXEC` descriptor.
- After the final public-binding fence, replay now creates a deterministic
  admission-serialized hard link in its validated owner-private control
  directory and verifies that alias against the pinned descriptor identity.
  Native launch uses only that stable alias and retains `repro.sh` as
  `argv[0]`; script launch remains descriptor-backed.
- The alias is removed with custody, stale crash debris is replaced on the next
  serialized attempt, and hosts where the hard link cannot be created fail
  closed with `descriptor_exec_unavailable`.
