# 2026-10-02 — Replay launches a descriptor-pinned artifact

- Replay previously checked public pathnames and then asked `exec` to resolve
  `repro.sh` again. Repeating `realpath` immediately before pathname execution
  would still let a replacement runs-root generation authorize its own script
  and would leave a final check-to-exec race, so that self-authorizing approach
  was rejected.
- Replay now pins the original non-symlink runs root, every selected directory,
  and the executable regular script by descriptor. A final public-binding fence
  rejects observed identity, type, or mode changes; launch then uses only an
  identity-checked `/proc/self/fd` or `/dev/fd` alias for the held script.
- A private, stable per-user XDG-state control directory supplies bounded
  nonblocking admission across configured-path, canonical-root, and root-
  identity keys. Busy contenders exit retryably without running an artifact,
  and the foreground supervisor retains admission through the top-level child.
- The closed v1 error envelope now carries replay-specific structural reasons,
  including `replay_busy`, lock/descriptor failures, entry-specific missing or
  changed states, and supervision uncertainty. The operator documentation names
  the recovery procedure and the same-inode, interpreter-resolution,
  abrupt-supervisor-death, and post-spawn exactly-once boundaries.
- `replay_safety_test.rb`, `hive_e2e_binary_test.rb`,
  `replay_portability_test.rb`, `schemas_test.rb`, and
  `managed_directory_test.rb` cover deterministic races, descriptor hygiene,
  contention/retry, real shebang and native launches, signal/status behavior,
  schema closure, and platform capability. Linux runs the portability file via
  `e2e:lib_test`; the existing advisory macOS 15 job now runs it directly for
  `/dev/fd`. A hosted green macOS run URL and commit SHA remain outstanding.
