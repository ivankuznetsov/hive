## 2026-07-28: Separate OpenClaw process-containment roles

**Action:** Replaced the creator proof's monolithic process runner with a thin
facade and explicit budget, parent session, child owner, target-capture worker,
Linux warden, process-tree, network, stream, status, and protocol
collaborators. The independently live child-subreaper owner is now the sole
writer of final teardown evidence, while the strict JSON/Base64 protocol keeps
the public process result shape unchanged.

**Safety:** Preserved one absolute parent and owner deadline, fork-local process
observation, explicit pipe closure, worker PID visibility/reset, full-stream
secret scanning beyond retained output, and differentiated TERM/KILL handling.
Sampler and stream/writer thread failures are now observed after bounded joins
and fail closed as typed containment failures. Added structural ownership
guards, focused failure characterizations, and repeated escaped-descendant
stress coverage.
